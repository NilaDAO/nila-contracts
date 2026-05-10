// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * External library with PURE math only.
 * Mark functions `internal` => inlines (bigger). Mark `public` => external call (smaller core).
 * We choose `public` PURE so the core calls via DELEGATECALL to the library address (linked),
 * which reduces core runtime bytecode size.
 */
library GenericFundMathLib {
    uint256 internal constant RAY = 1e27;
    uint256 constant WAD = 1e18;

    struct RateParams {
        uint16 baseRateBP;   // e.g., 600 = 6.00%
        uint16 kinkUtilBP;   // 0..10000 (basis points of utilization)
        uint16 slope1BP;     // extra bps across 0..kink
        uint16 slope2BP;     // extra bps across kink..1
        uint16 maxRateBP;    // hard ceiling
    }
    
    function accruePending(uint256 shares, uint256 entryIndex, uint256 currentIndex) public pure returns (uint256) {
        if (shares == 0 || currentIndex == 0 || currentIndex <= entryIndex) return 0;
        uint256 delta = currentIndex - entryIndex;
        return Math.mulDiv(shares, delta, RAY);
    }

    function toShares(uint256 amount, uint256 supplyIndex) public pure returns (uint256) {
        return (amount * RAY) / supplyIndex;
    }

    function toUnderlying(uint256 shares, uint256 supplyIndex) public pure returns (uint256) {
        return (shares * supplyIndex) / RAY;
    }

    function haircutIndex(uint256 supplyIndex, uint256 underlying, uint256 loss)
        public
        pure
        returns (uint256 applied, uint256 newIndex)
        {
        if (loss == 0 || underlying == 0) return (0, supplyIndex);
        applied = loss > underlying ? underlying : loss;
        uint256 kept = underlying - applied;
        newIndex = kept == 0 ? 1 : (supplyIndex * kept) / underlying;
    }

    function accruedInterest(uint256 principal, uint16 rateBP, uint256 elapsed, uint256 year)
        public
        pure
        returns (uint256)
    {
        return (principal * rateBP * elapsed) / (10_000 * year);
    }

    /// @dev Returns `index` if non-zero, else RAY. Avoids repeated ternaries in Core.
    ///      Internal so it inlines — the function body is too small to justify a DELEGATECALL.
    function normalizeIndex(uint256 index) internal pure returns (uint256) {
        return index == 0 ? RAY : index;
    }

    /// @dev Basis-point fee: `amount * bp / 10_000`. Returns 0 when skip is true or bp == 0.
    ///      Internal so it inlines.
    function bpFee(uint256 amount, uint16 bp, bool skip) internal pure returns (uint256) {
        if (skip || bp == 0) return 0;
        return (amount * uint256(bp)) / 10_000;
    }

    /// @dev Apply a loss to a tranche index. Wraps toUnderlying + haircutIndex.
    ///      Public so Core calls it via DELEGATECALL — worth the overhead at this size.
    function applyLoss(uint256 supplyIndex, uint256 totalShares, uint256 loss)
        public pure returns (uint256 applied, uint256 newIndex)
    {
        if (loss == 0 || supplyIndex == 0 || totalShares == 0) return (0, supplyIndex);
        uint256 underlying = toUnderlying(totalShares, supplyIndex);
        if (underlying == 0) return (0, supplyIndex);
        (applied, newIndex) = haircutIndex(supplyIndex, underlying, loss);
    }

    function quoteRateBP(
        RateParams memory p,
        uint256 borrows,
        uint256 liquidity,
        uint256 addAmount
    ) public pure returns (uint16) {
        uint256 totalAssets = borrows + liquidity;
        if (totalAssets == 0) return p.baseRateBP;

        // util in WAD, clamped to [0, 1e18]
        uint256 utilWad = Math.mulDiv(borrows + addAmount, WAD, totalAssets);
        if (utilWad > WAD) utilWad = WAD;

        // kink in WAD: kinkBP/10000 * 1e18 = kinkBP * 1e14
        uint256 kinkWad = uint256(p.kinkUtilBP) * 1e14;

        uint256 rate = uint256(p.baseRateBP);

        if (utilWad <= kinkWad) {
            // linear pre-kink
            if (kinkWad > 0) {
                uint256 frac1 = Math.mulDiv(utilWad, WAD, kinkWad); // 0..1e18
                rate += Math.mulDiv(uint256(p.slope1BP), frac1, WAD);
            }
        } else {
            // full pre-kink slope
            rate += uint256(p.slope1BP);

            uint256 denom = WAD - kinkWad;
            if (denom == 0) {
                // kink at 100%: treat any post-kink util as full slope2
                rate += uint256(p.slope2BP);
            } else {
                // linear fraction (0..1e18) across post-kink band:
                uint256 frac2 = Math.mulDiv(utilWad - kinkWad, WAD, denom);

                // ***** convex steepening: square the fraction in WAD-space *****
                // For even sharper hockey-stick, square again (i.e., cube: frac2Q = (frac2^3)/WAD^2).
                uint256 frac2Q = Math.mulDiv(frac2, frac2, WAD);      // quadratic
                // uint256 frac2Q = Math.mulDiv(Math.mulDiv(frac2, frac2, WAD), frac2, WAD); // ← cubic

                rate += Math.mulDiv(uint256(p.slope2BP), frac2Q, WAD);
            }
        }

        if (rate > uint256(p.maxRateBP)) rate = uint256(p.maxRateBP);
        return uint16(rate);
    }
}
