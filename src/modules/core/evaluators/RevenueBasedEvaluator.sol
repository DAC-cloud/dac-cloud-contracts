// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IEvaluator} from "../../../interfaces/IEvaluator.sol";
import {IDealCell} from "../../../interfaces/IDealCell.sol";
import {EvaluationResult} from "../../../interfaces/Structs.sol";
import {MathLib} from "../../../kernel/libraries/MathLib.sol";

contract RevenueBasedEvaluator is IEvaluator {
    /*//////////////////////////////////////////////////////////////
                          STATE & IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable dac;
    uint256 public immutable dealId;
    address public immutable cell;

    // Configurable parameters (set once at deployment)
    struct Config {
        address token;                  // revenue accounting token
        uint256 duration;               // period length (e.g. 30 days)
        uint256 baseExpected;           // base expected revenue per period
        int256[] curveCoeffs;           // polynomial coeffs (a + b*x + c*x² + d*x³)
        uint256 maxCycleUnlockPercent;  // minimum unlock even if below target (forgiving)
        uint256 minCycleRevenuePercent; // minimal revenue percent before counting as miss
        uint256 graceCycles;            // consecutive misses before slashing starts
        uint256 penaltyPerMiss;         // small penalty % per missed cycle
        uint256 evaluationStart;        // timestamp for starting evaluation, if 0 - starting at deal start
    }

    Config public config;

    // Stateful tracking
    uint256 public lastChecked;
    uint256 public unlockedRewards;     // total % unlocked so far (scaled)
    uint256 public returnsSnapshot;
    uint256 public missedCycles;
    uint256 public updatedDeadline;

    constructor(
        address _dac,
        uint256 _dealId,
        address _cell,
        bytes memory _configData
    ) {
        dac = _dac;
        dealId = _dealId;
        cell = _cell;

        config = abi.decode(_configData, (Config));

        lastChecked = block.timestamp;
        updatedDeadline = IDealCell(_cell).dealDeadline();
    }

    function permitMint(address, address, uint256) external pure returns (bool permit) {
        // Basic evaluator will not do any additional authorization for unlocking LP rewards.
        // However it would be a good practice for external modules to allow such a protection.

        // With permitMint implemented evaluator can become an oracle for last-resort protection between
        //  vulnerabilities in the particular Deal contract.
        
        // Basic logic for evaluator - revert any mintLP call, until someone presses the button on the web
        //  and signs with EOA, then there is a 12 hours window, and if no other EOA objects and provide
        //  to an AI agent reasonable claims about a hack in a Deal - evaluator approves the single mint

        return true;
    }

    /*//////////////////////////////////////////////////////////////
                          EVALUATE LOGIC
    //////////////////////////////////////////////////////////////*/

    function evaluateDeal(uint256, address, address, address) external override returns (EvaluationResult[] memory) {
        uint256 current = block.timestamp;

        uint256 totalCapitalReturned = IDealCell(cell).getReturnedCapital(config.token);
        uint256 returned = totalCapitalReturned - returnsSnapshot;
        returnsSnapshot = totalCapitalReturned;

        //todo: periods should start at deal or specified timestamp (evaluatonStart)
        //todo: periods should be "exact", and not depending on when in the middle of period the contract was called

        // How many full periods passed
        uint256 cycles = (current - lastChecked) / config.duration;
        if (cycles == 0) {
            return new EvaluationResult[](0); // nothing to evaluate yet
        }

        uint256 rewardPercent = 0;
        uint256 penalties = 0;

        for (uint256 c = 0; c < cycles; c++) {
            // Cycle revenue (cumulative returned divided by a number of cycles for simplicity)
            uint256 cycleRevenue = returned / cycles;

            // x = progress (0 to 1+)
            uint256 progressScaled = MathLib.div(cycleRevenue, config.baseExpected);

            // Evaluate polynomial curve: y = reward % (0 to 1)
            int256 x = int256(progressScaled);
            int256 curveResult = _evaluatePolynomial(x);

            // Reward percent capped by `config.maxCycleUnlockPercent` and deployed
            // proportional to revenue results with curve applied
            rewardPercent += MathLib.mul(
                config.maxCycleUnlockPercent, 
                MathLib.capAt100(uint256(curveResult))
            );

            // Check for miss
            if (progressScaled < MathLib.mul(config.minCycleRevenuePercent, MathLib.SCALE)) {
                missedCycles++;
                if (missedCycles > config.graceCycles) {
                    penalties++; // todo: let's calculate miss also pro-rata, linearly without curve with minCycleRevenuePercent as base
                }
            } else {
                missedCycles = 0;
            }
        }

        //todo: not to current time, but at the "end" of the current cycle
        // so when called next time we will start loop at that timestamp...
        lastChecked = current;

        EvaluationResult[] memory results = new EvaluationResult[](3); // producing max 3 results
        uint256 resultIndex = 0;

        // Unlock
        if (MathLib.capAt100(unlockedRewards + rewardPercent) < unlockedRewards + rewardPercent) {
            rewardPercent = MathLib.SCALE - unlockedRewards;
        }

        results[resultIndex++] = EvaluationResult(1, rewardPercent, 0);
        unlockedRewards += rewardPercent;

        // Slashing
        if (penalties > 0) {
            results[resultIndex++] = EvaluationResult(0, MathLib.capAt100(config.penaltyPerMiss * penalties), 0);
        }

        // Auto-close if fully unlocked
        if (unlockedRewards >= MathLib.SCALE) {
            results[resultIndex++] = EvaluationResult(3, 0, 0); // close
        }
        
        // Resize array
        assembly {
            mstore(results, resultIndex)
        }

        return results;
    }

    /*//////////////////////////////////////////////////////////////
                          POLYNOMIAL EVALUATION (Horner)
    //////////////////////////////////////////////////////////////*/

    function _evaluatePolynomial(int256 x) internal view returns (int256 y) {
        int256[] memory coeffs = config.curveCoeffs;
        y = coeffs[coeffs.length - 1];

        for (int256 i = int256(coeffs.length) - 2; i >= 0; i--) {
            if (y < 0) {
                y = - int256(MathLib.mulDiv(uint256(y), uint256(x), MathLib.SCALE)) + coeffs[uint256(i)];
            }
            else {
                y = int256(MathLib.mulDiv(uint256(y), uint256(x), MathLib.SCALE)) + coeffs[uint256(i)];
            }
        }

        // Cap at 100%
        if (y > int256(MathLib.SCALE)) y = int256(MathLib.SCALE);
        if (y < 0) y = 0;
    }
}