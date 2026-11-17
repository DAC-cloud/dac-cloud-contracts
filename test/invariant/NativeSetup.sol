// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./NativeBase.sol";
import {MilestoneBasedEvaluator} from "../../src/modules/core/evaluators/MilestoneBasedEvaluator.sol";
import {RevenueBasedEvaluator} from "../../src/modules/core/evaluators/RevenueBasedEvaluator.sol";
import {
    Milestone,
    RevenueSchedule,
    DACDealConfig,
    TreasurySpendAllowance
} from "../../src/modules/core/interfaces/Structs.sol";

/// System deployment, deal construction and the seeded initial state.
abstract contract NativeSetup is NativeBase {
    uint256 internal constant MAX_DEALS = 9;
    uint256 internal _saltNonce;
    bool public initialized;

    // ------------------------------------------------------------------ //
    // Deployment                                                           //
    // ------------------------------------------------------------------ //
    function init() external {
        require(!initialized, "init once");
        initialized = true;

        vm.warp(1_700_000_000);

        usdc = new InvToken("USD Coin", "USDC", 6);
        tok2 = new InvToken("Dai Stablecoin", "DAI", 18);
        permit2 = new InvPermit2();
        oracle = new InvOracle();
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(tok2), 1e18);

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string.concat("actor-", vm.toString(i))));
        }
        sinks.push(makeAddr("sink-0"));
        sinks.push(makeAddr("sink-1"));

        _deployProtocol();
        _deployDac();
        _seedState();
    }

    function _deployProtocol() internal {
        vm.startPrank(moduleOwner);

        coreDealGov = new CoreManagementProposalFactory();

        coreModule = new CoreModuleFactory(
            address(new DACDealFactory()),
            address(new TreasuryDealFactory(address(permit2))),
            address(new AgentDealFactory()),
            address(new MilestoneEvaluatorFactory()),
            address(new RevenueEvaluatorFactory()),
            address(coreDealGov)
        );

        dacFactory = new DACFactory(
            [
                address(new MainTokenFactory()),
                address(new AgentTokenFactory()),
                address(new DACCellFactory()),
                address(new DealManagerFactory()),
                address(new ModuleRegistryFactory()),
                address(new NativeAssetControllerFactory()),
                address(new DACManagementProposalFactory()),
                address(new NativeGovernanceSchemaFactory()),
                address(coreModule),
                address(new DealCellFactory()),
                address(new StakedAgentFactory())
            ],
            [
                address(new ExistingTokenAssetControllerFactory()),
                address(new HybridDACManagementProposalFactory()),
                address(new HybridGovernanceSchemaFactory()),
                address(new WrappedMainTokenFactory()),
                address(new GovernanceOracleFactory())
            ]
        );

        mockModule = new MockEvaluatorModuleFactory(
            address(new TreasuryDealFactory(address(permit2))), address(new MockEvaluatorFactory())
        );

        vm.stopPrank();
    }

    function _deployDac() internal {
        DACConfig memory config = DACConfig({
            symbol: "DACX",
            name: "DAC exchange",
            description: "invariant campaign",
            mainTokenMaxSupply: 1_000_000_000e18,
            defaultQuorum: MathLib.atScale(50),
            founder: founder,
            founderAllocation: 200_000_000e18,
            treasuryToken: address(usdc),
            founderCommitment: 20_000e6,
            dividendsEnabled: true
        });

        usdc.mint(founder, 20_000e6);

        vm.startPrank(founder);
        (address dacAddr, address mainAddr, address agentAddr) =
            dacFactory.deployDAC(config, keccak256("inv-root-dac"), address(0));

        dac = DACCell(dacAddr);
        mainToken = MainToken(mainAddr);
        agentToken = AgentToken(agentAddr);
        dealManager = DealManager(dac.getDealManager());
        controller = dac.getAssetController();

        usdc.approve(controller, 20_000e6);
        dac.fulfillCapitalCall(
            CapitalCall({
                treasuryToken: address(usdc),
                nonce: 0,
                tokenRecipient: founder,
                tokenAmount: 200_000_000e18,
                cashAmount: 20_000e6
            })
        );
        mainToken.delegate(founder);
        vm.stopPrank();

        ghostIn[address(usdc)] += 20_000e6;
        ghostTreasuryCredits[address(usdc)] += int256(uint256(20_000e6));
        ghostMainMintedByCalls += 200_000_000e18;

        _addPerimeter(address(dac));
        _addPerimeter(controller);
        _addPerimeter(address(dealManager));
        _addPerimeter(address(agentToken));
        _addPerimeter(address(mainToken));

        controlledList.push(address(dac));
        controlledList.push(controller);
        controlledList.push(address(dealManager));
        controlledList.push(address(agentToken));
    }

    function _seedState() internal {
        // Holders: every actor owns and self-delegates some main token.
        for (uint256 i = 0; i < actors.length; i++) {
            vm.prank(founder);
            mainToken.transfer(actors[i], 4_000_000e18);
            vm.prank(actors[i]);
            mainToken.delegate(actors[i]);
        }
        vm.warp(block.timestamp + 1);

        // Mock evaluator module
        _passDac(
            ProposalParams({
                typ: DACManagementProposalType.ADD_MODULE, target: address(mockModule), i: 0, data: bytes("")
            }),
            founder
        );

        // Agents
        for (uint256 i = 0; i < 4; i++) {
            _passDac(
                ProposalParams({
                    typ: DACManagementProposalType.MINT_AGENT_TOKENS,
                    target: actors[i],
                    i: bytes32(uint256(1_000_000)),
                    data: bytes("")
                }),
                founder
            );
        }

        // Treasury depth in both cash tokens
        _seedCapitalCall(actors[0], address(usdc), 10_000_000e18, 1_000_000e6);
        _seedCapitalCall(actors[1], address(tok2), 10_000_000e18, 1_000_000e18);

        // Seeded deals: 0 treasury/mock, 1 treasury/milestone, 2 treasury/revenue, 3 dac/mock (all approved),
        // 4 treasury/mock left unapproved.
        uint256 d0 = _createDeal(
            _seedParams(actors[0], KIND_TREASURY, EVAL_MOCK, 10_000e6, MathLib.atScale(20)), KIND_TREASURY, EVAL_MOCK
        );
        _seedStakeApprove(d0, actors[0], actors[1]);

        uint256 d1 = _createDeal(
            _seedParams(actors[1], KIND_TREASURY, EVAL_MILESTONE, 5_000e6, 0), KIND_TREASURY, EVAL_MILESTONE
        );
        _seedStakeApprove(d1, actors[1], actors[2]);

        uint256 d2 =
            _createDeal(_seedParams(actors[2], KIND_TREASURY, EVAL_REVENUE, 5_000e6, 0), KIND_TREASURY, EVAL_REVENUE);
        _seedStakeApprove(d2, actors[2], actors[3]);

        uint256 d3 = _createDeal(
            _seedParams(actors[3], KIND_DAC, EVAL_MOCK, 10_000e6, MathLib.atScale(10)), KIND_DAC, EVAL_MOCK
        );
        _seedStakeApprove(d3, actors[3], actors[0]);

        // deal 0 runs with early returns enabled
        _passDeal(
            d0,
            actors[0],
            ProposalParams({
                typ: AbstractDealManagementType.TOGGLE_EARLY_RETURNS, target: address(0), i: 0, data: abi.encode(true)
            })
        );

        uint256 d4 = _createDeal(_seedParams(actors[0], KIND_TREASURY, EVAL_MOCK, 2_000e6, 0), KIND_TREASURY, EVAL_MOCK);
        vm.prank(actors[0]);
        agentToken.stakeToDeal(_deals[d4].cell, 10_000);
        _addStaker(d4, actors[0]);
    }

    function _seedCapitalCall(address recipient, address token, uint256 tokenAmount, uint256 cash) internal {
        _passDac(
            ProposalParams({
                typ: DACManagementProposalType.CAPITAL_CALL,
                target: recipient,
                i: bytes32(tokenAmount),
                data: abi.encode(token, cash, CALL_EXPIRY)
            }),
            founder
        );
        _fulfil(_calls.length - 1);
    }

    function _seedStakeApprove(uint256 di, address a, address b) internal {
        DealInfo storage d = _deals[di];
        vm.prank(a);
        agentToken.stakeToDeal(d.cell, 20_000);
        _addStaker(di, a);
        vm.prank(a);
        IDealCell(d.cell).invite(b, true);
        vm.prank(b);
        agentToken.stakeToDeal(d.cell, 20_000);
        _addStaker(di, b);

        _voteDacAll(dac.getProposalVoting(d.approvePid));
        _execDac(d.approvePid);
        vm.warp(block.timestamp + 1);
    }

    // ------------------------------------------------------------------ //
    // Capital-call fulfilment (shared by seed + handler)                   //
    // ------------------------------------------------------------------ //
    function _fulfil(uint256 ci) internal {
        CallInfo storage c = _calls[ci];
        CapitalCall memory call = c.call;
        _allowLoss(call.tokenRecipient);

        InvToken(call.treasuryToken).mint(call.tokenRecipient, call.cashAmount);
        vm.prank(call.tokenRecipient);
        InvToken(call.treasuryToken).approve(controller, call.cashAmount);

        dac.fulfillCapitalCall(call);

        c.fulfilled = true;
        ghostIn[call.treasuryToken] += call.cashAmount;
        ghostTreasuryCredits[call.treasuryToken] += int256(call.cashAmount);
        ghostMainMintedByCalls += call.tokenAmount;

        if (mainToken.delegates(call.tokenRecipient) == address(0)) {
            vm.prank(call.tokenRecipient);
            mainToken.delegate(call.tokenRecipient);
        }
    }

    // ------------------------------------------------------------------ //
    // Deal construction                                                    //
    // ------------------------------------------------------------------ //
    function _oneCoeff(int256 c) internal pure returns (int256[] memory a) {
        a = new int256[](1);
        a[0] = c;
    }

    function _seedMilestoneConfig(address token) internal view returns (bytes memory) {
        Milestone[] memory ms = new Milestone[](1);
        ms[0] = Milestone({
            milestoneType: 1,
            token: token,
            oracle: address(0),
            valuationMode: 0,
            fundingToken: address(0),
            expectedReturn: 5_000e6,
            timestamp: block.timestamp + 10 days,
            rewardPercentage: 1e18,
            rewardCurve: _oneCoeff(5e17),
            penaltyCurve: _oneCoeff(5e17),
            minPercentGrace: 0,
            extension: 0,
            excludePrincipal: false
        });
        return abi.encode(MilestoneBasedEvaluator.Config(MathLib.atScale(100), ms));
    }

    function _seedRevenueConfig(address token) internal pure returns (bytes memory) {
        int256[] memory curve = new int256[](2);
        curve[0] = 0;
        curve[1] = 1e18;
        RevenueSchedule memory s = RevenueSchedule({
            token: token,
            duration: 1 days,
            revenueProjectionMode: 0,
            revenueProjection: 100e6,
            curveCoeffs: curve,
            requirementCurveCoeffs: _oneCoeff(1e18),
            maxCycleUnlockPercent: 1e17,
            minCycleRevenuePercent: 5e17,
            graceCycles: 2,
            penaltyPerMiss: 5e16,
            evaluationStart: 0,
            autoClose: true,
            excludePrincipal: false
        });
        return abi.encode(RevenueBasedEvaluator.Config(MathLib.atScale(100), s));
    }

    function _childDealConfig(address fundingToken, uint256 fundingAmount, uint256 equity)
        internal
        returns (bytes memory)
    {
        DACConfig memory child = DACConfig({
            symbol: "CHILD",
            name: string.concat("Child DAC ", vm.toString(_saltNonce)),
            description: "child",
            mainTokenMaxSupply: 1_000_000_000e18,
            defaultQuorum: MathLib.atScale(50),
            founder: founder, // replaced by the deal
            founderAllocation: equity,
            treasuryToken: fundingToken,
            founderCommitment: fundingAmount,
            dividendsEnabled: false
        });
        bytes32 salt = keccak256(abi.encode("inv-child", _saltNonce++));
        return abi.encode(
            DACDealConfig({managedEquity: equity, config: abi.encode(address(dacFactory), address(0), salt, child)})
        );
    }

    function _seedParams(address agent, uint8 kind, uint8 evalKind, uint256 funding, uint256 poolPct)
        internal
        returns (DealParams memory p)
    {
        p = DealParams({
            dealKind: kind == KIND_DAC ? CoreDealType.DAC_DEAL : CoreDealType.PERMIT2_TREASURY,
            name: "Seed deal",
            description: "seed",
            linkHash: "",
            moduleFactory: address(coreModule),
            governanceFactory: address(coreDealGov),
            dealTarget: address(0),
            proposer: agent,
            vetoEnabled: false,
            fundingToken: address(usdc),
            fundingAmount: funding,
            rewardsLimit: 1_000_000e18,
            dealRewardPoolPercent: poolPct,
            approveDeadline: block.timestamp + 5 days,
            evaluationDeadline: block.timestamp + 8 days,
            dealDeadline: block.timestamp + 20 days,
            dealConfig: kind == KIND_DAC ? _childDealConfig(address(usdc), funding, 1_000_000e18) : abi.encode("cfg"),
            evaluatorSelector: bytes4(0),
            evaluatorConfig: bytes(""),
            evaluatorModuleFactory: address(0),
            agentsLimit: 0,
            minimalStake: 0
        });
        _setEvaluator(
            p,
            evalKind,
            evalKind == EVAL_MILESTONE ? _seedMilestoneConfig(address(usdc)) : _seedRevenueConfig(address(usdc))
        );
    }

    function _setEvaluator(DealParams memory p, uint8 evalKind, bytes memory realConfig) internal view {
        if (evalKind == EVAL_MOCK) {
            p.evaluatorSelector = MOCK_EVALUATOR_SELECTOR;
            p.evaluatorConfig = abi.encode(address(this), new EvaluationResult[](0));
            p.evaluatorModuleFactory = address(mockModule);
        } else if (evalKind == EVAL_MILESTONE) {
            p.evaluatorSelector = CoreEvaluatorType.MILESTONES_EVALUATOR;
            p.evaluatorConfig = realConfig;
        } else {
            p.evaluatorSelector = CoreEvaluatorType.REVENUE_EVALUATOR;
            p.evaluatorConfig = realConfig;
        }
    }

    // Creates the deal through the kernel and registers it with the harness.
    function _createDeal(DealParams memory p, uint8 kind, uint8 evalKind) internal returns (uint256 di) {
        _syncDacPids();
        uint256 pidBefore = dacPidHigh;
        vm.prank(p.proposer);
        (uint256 id, address cell, address deal, address evaluator) = dealManager.createDealProposal(p);
        _syncDacPids();
        require(dacPidHigh == pidBefore + 1, "harness: approve proposal not found");

        di = _deals.length;
        _deals.push();
        DealInfo storage d = _deals[di];
        d.id = id;
        d.cell = cell;
        d.deal = deal;
        d.evaluator = evaluator;
        d.approvePid = dacPidHigh;
        d.kind = kind;
        d.evalKind = evalKind;
        d.stake = IDealCell(cell).stakeToken();
        _dealIdxPlus1[id] = di + 1;

        _addPerimeter(cell);
        _addPerimeter(deal);
        _addPerimeter(evaluator);
        _addPerimeter(d.stake);
        controlledList.push(cell);
        controlledList.push(deal);

        if (kind == KIND_TREASURY) {
            d.treasury = Deal(deal).managedEntity();
            _addPerimeter(d.treasury);
            controlledList.push(d.treasury);
        } else {
            d.childDac = Deal(deal).managedEntity();
            d.childMain = IDACCell(d.childDac).getMainToken();
            d.childController = IDACCell(d.childDac).getAssetController();
            _addPerimeter(d.childDac);
            _addPerimeter(d.childController);
            _addPerimeter(IDACCell(d.childDac).getDealManager());
        }

        if (evalKind == EVAL_MOCK) _mockEvaluators[di].push(evaluator);
    }
}
