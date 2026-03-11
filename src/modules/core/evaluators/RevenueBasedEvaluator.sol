// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {IEvaluator} from "../../../interfaces/IEvaluator.sol";
import {IDealCell} from "../../../interfaces/IDealCell.sol";
import {EvaluationResult} from "../../../interfaces/Structs.sol";
import {MathLib} from "../../../kernel/libraries/MathLib.sol";
import {RevenueSchedule} from "../interfaces/Structs.sol";

contract RevenueBasedEvaluator is IEvaluator, Initializable {

    error NotInitialized();
    error RevenueBaseMisconfigured();

    bool private initialized;

    address public dac;
    uint256 public dealId;
    address public cell;

    struct Config {
        uint256 rewardShare;            // e.g. MathLib.atScale(70) (70% of total rewards)
        RevenueSchedule schedule;
    }

    Config public config;

    // Stateful tracking
    uint256 public lastChecked;
    uint256 public unlockedRewards;     // total % unlocked so far (scaled)
    uint256 public returnsSnapshot;
    uint256 public totalEvaluatedCycles;
    uint256 public missedCycles;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _dac,
        uint256 _dealId,
        address _cell,
        bytes memory _configData
    ) external initializer {
        initialized = true;

        dac = _dac;
        dealId = _dealId;
        cell = _cell;

        config = abi.decode(_configData, (Config));

        uint256 start = config.schedule.evaluationStart == 0 ? block.timestamp : config.schedule.evaluationStart;
        lastChecked = start;
    }

    function permitMint(address, address, uint256) external view override returns (bool permit) {
        require(initialized, NotInitialized());

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
        require(initialized, NotInitialized());

        uint256 current = block.timestamp;

        // Align to exact period boundaries (no lost partial cycles)
        uint256 nextCycleStart = lastChecked + config.schedule.duration;
        if (current < nextCycleStart) {
            return new EvaluationResult[](0);
        }

        // How many full periods passed
        uint256 cycles = (current - lastChecked) / config.schedule.duration;
        if (cycles == 0) {
            return new EvaluationResult[](0); // nothing to evaluate yet
        }

        // Taking revenue snapshot
        uint256 totalCapitalReturned = IDealCell(cell).getReturnedCapital(config.schedule.token);
        uint256 returned = totalCapitalReturned - returnsSnapshot;
        returnsSnapshot = totalCapitalReturned;

        // Calculating revenue target
        uint256 baseExpectedRevenue = config.schedule.revenueProjection;
        if (config.schedule.revenueProjectionMode != 0) {
            uint256 investedCapital = IDealCell(cell).getInvestedCapital(config.schedule.token);
            require(investedCapital > 0, RevenueBaseMisconfigured());

            baseExpectedRevenue = investedCapital / config.schedule.revenueProjection;
        }

        uint256 rewardPercent = 0;
        uint256 penalties = 0;

        for (uint256 c = 0; c < cycles; c++) {
            // Cycle revenue (cumulative returned divided by a number of cycles for simplicity)
            //  If multiple cycles passed, we have no reasonable way to retrieve proper figures
            //  per cycle, even if the targets per cycle are different by curve. So agents are
            //  advised to evaluate deals each cycle (or try to delay evaluation if there is a
            //  miss in revenue, therefore it can be in future covered by future cycles).
            //  DAC main token holders only receives the right to evaluate after deal deadline.
            uint256 cycleRevenue = returned / cycles;

            uint256 expected = _evaluateRequirement(totalEvaluatedCycles + c, baseExpectedRevenue);

            // x = progress (0 to 1+)
            uint256 progressScaled = MathLib.div(cycleRevenue, expected);

            // Evaluate polynomial curve: y = reward % (0 to 1)
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 x = int256(progressScaled);
            int256 curveResult = _evaluatePolynomial(x);

            // Reward percent capped by `config.maxCycleUnlockPercent` and deployed
            //  proportional to revenue results with curve applied

            rewardPercent += MathLib.mul(
                config.schedule.maxCycleUnlockPercent,
                // casting `curveResult` to 'uint256' is safe because `curveResult` is always in [0..1] range
                // forge-lint: disable-next-line(unsafe-typecast)
                uint256(curveResult)
            );

            // Check for miss
            if (progressScaled < MathLib.mul(config.schedule.minCycleRevenuePercent, MathLib.SCALE)) {
                missedCycles++;
                if (missedCycles > config.schedule.graceCycles) {
                    penalties++;
                }
            } else {
                missedCycles = 0;
            }
        }

        // Next evaluation starts at the end of the last completed cycle
        lastChecked = lastChecked + cycles * config.schedule.duration;
        totalEvaluatedCycles += cycles;

        EvaluationResult[] memory results = new EvaluationResult[](3); // producing max 3 results
        uint256 resultIndex = 0;

        // Unlock
        if (rewardPercent > 0) {
            if (unlockedRewards + rewardPercent > config.rewardShare) {
                rewardPercent = config.rewardShare - unlockedRewards;
            }

            if (rewardPercent > 0) {
                results[resultIndex++] = EvaluationResult(1, rewardPercent, 0);
                unlockedRewards += rewardPercent;
            }
        }

        // Slashing
        if (penalties > 0) {
            results[resultIndex++] = EvaluationResult(0, MathLib.capAt100(config.schedule.penaltyPerMiss * penalties), 0);
        }

        // Auto-close if fully unlocked
        if (config.schedule.autoClose && unlockedRewards >= config.rewardShare) {
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
        int256[] memory coeffs = config.schedule.curveCoeffs;
        y = coeffs[coeffs.length - 1];

        for (int256 i = int256(coeffs.length) - 2; i >= 0; i--) {
            // casting `i` to 'uint256' is safe because if `coeffs.lengths <= 1` we're not entering the cycle
            // forge-lint: disable-next-line(unsafe-typecast)
            y = MathLib.mulDivSigned(y, x, MathLib.SCALE) + coeffs[uint256(i)];
        }

        // Cap at 100%
        if (y > int256(MathLib.SCALE)) y = int256(MathLib.SCALE);
        if (y < 0) y = 0;
    }

    /// @dev Requirement curve (cycle number → expected revenue)
    function _evaluateRequirement(uint256 cycle, uint256 baseCycleRevenue) internal view returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 x = int256(cycle * MathLib.SCALE);
        int256[] memory coeffs = config.schedule.requirementCurveCoeffs;
        int256 y = coeffs[coeffs.length - 1];
        for (int256 i = int256(coeffs.length) - 2; i >= 0; i--) {
            // casting `i` to 'uint256' is safe because if `coeffs.lengths <= 1` we're not entering the cycle
            // forge-lint: disable-next-line(unsafe-typecast)
            y = MathLib.mulDivSigned(y, x, MathLib.SCALE) + coeffs[uint256(i)];
        }
        if (y < 0) y = 0;
        // casting to 'uint256' is safe because y > 0
        // forge-lint: disable-next-line(unsafe-typecast)
        return MathLib.mul(uint256(y), baseCycleRevenue); // always at least base
    }
}