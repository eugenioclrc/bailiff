// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockRWA3643 as MockRWA} from "../../src/e2e/MockRWA3643.sol";
import {MiniLend} from "../../src/e2e/MiniLend.sol";
import {MockUSDC, SimVenue, SimAdapter} from "./sim/Sim.sol";

contract Handler is Test {
    MockRWA public rwa;
    MockUSDC public usdc;
    MiniLend public lend;
    SimVenue public venue;
    SimAdapter public adapter;
    address public issuer;
    address public oracle;
    address public kycLiq = makeAddr("kycLiq");
    address public richAnon = makeAddr("richAnon"); // has USDC, not allowlisted
    address[3] public borrowers = [makeAddr("b0"), makeAddr("b1"), makeAddr("b2")];
    address[3] public keepers = [makeAddr("k0"), makeAddr("k1"), makeAddr("k2")];

    mapping(address => uint256) public ghostBounty;
    uint256 public ghostLiqs;
    bool public violBountyCap;
    bool public violSeizeBound;
    bool public violHealthyLiq;
    bool public violAnonDirect;

    constructor(MockRWA r, MockUSDC u, MiniLend l, SimVenue v, SimAdapter a, address issuer_, address oracle_) {
        (rwa, usdc, lend, venue, adapter, issuer, oracle) = (r, u, l, v, a, issuer_, oracle_);
        vm.startPrank(issuer);
        for (uint256 i; i < 3; i++) rwa.setFlags(borrowers[i], rwa.HOLDER() | rwa.SWAP());
        rwa.setFlags(kycLiq, rwa.HOLDER());
        vm.stopPrank();
        usdc.mint(richAnon, 1e15);
        usdc.mint(kycLiq, 1e15);
        vm.prank(richAnon); usdc.approve(address(lend), type(uint256).max);
        vm.prank(kycLiq); usdc.approve(address(lend), type(uint256).max);
    }

    function deposit(uint256 b, uint256 amt) external {
        address who = borrowers[b % 3];
        amt = bound(amt, 1e18, 5_000e18);
        vm.prank(issuer); rwa.mint(who, amt);
        vm.startPrank(who);
        rwa.approve(address(lend), amt);
        lend.depositCollateral(amt);
        vm.stopPrank();
    }

    /// @dev steering action: deposit + borrow at max LTV in one call so liquidatable states are reached often
    function openMaxPosition(uint256 b, uint256 amt) external {
        this.deposit(b, amt);
        this.borrow(b, 100);
    }

    function borrow(uint256 b, uint256 pct) external {
        address who = borrowers[b % 3];
        (uint256 c, uint256 d) = lend.positions(who);
        uint256 cap = lend.collateralValue(c) * lend.LTV_BPS() / 10_000;
        if (cap <= d) return;
        uint256 amt = (cap - d) * bound(pct, 1, 100) / 100;
        if (amt == 0) return;
        vm.prank(who);
        try lend.borrow(amt) {} catch {}
    }

    function repay(uint256 b, uint256 amt) external {
        address who = borrowers[b % 3];
        amt = bound(amt, 1, 50_000e6);
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(lend), amt);
        lend.repay(who, amt);
        vm.stopPrank();
    }

    function moveNav(int256 bps, int256 poolSkewBps) external {
        bps = bound(bps, -1_500, 800); // drift down so liquidations actually happen
        poolSkewBps = bound(poolSkewBps, -300, 300);
        uint256 n = uint256(int256(lend.nav()) * (10_000 + bps) / 10_000);
        n = bound(n, 2e18, 1_000e18);
        vm.prank(oracle);
        lend.setNav(n);
        uint256 x = rwa.balanceOf(address(venue));
        uint256 targetY = x * n / 1e30 * uint256(10_000 + poolSkewBps) / 10_000;
        uint256 y = usdc.balanceOf(address(venue));
        if (y > targetY) { vm.prank(address(venue)); usdc.transfer(address(0xdead), y - targetY); }
        else usdc.mint(address(venue), targetY - y);
    }

    function thinPool(uint256 keepPct) external {
        keepPct = bound(keepPct, 40, 100);
        uint256 x = rwa.balanceOf(address(venue));
        uint256 y = usdc.balanceOf(address(venue));
        vm.startPrank(address(venue));
        rwa.transfer(issuer, x - x * keepPct / 100);
        usdc.transfer(address(0xdead), y - y * keepPct / 100);
        vm.stopPrank();
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 1, 30 hours)); // sometimes crosses the 24h staleness window
    }

    function refillPool(uint256 amt) external {
        amt = bound(amt, 1_000e18, 50_000e18);
        uint256 x = rwa.balanceOf(address(venue));
        uint256 y = usdc.balanceOf(address(venue));
        vm.prank(issuer); rwa.mint(address(venue), amt);
        usdc.mint(address(venue), y * amt / x);
    }

    function liquidateViaAdapter(uint256 k, uint256 b, uint256 repayAmt, uint256 minBounty) external {
        address keeper = keepers[k % 3];
        address who = borrowers[b % 3];
        uint256 preHf = lend.healthFactor(who);
        repayAmt = bound(repayAmt, 1e6, type(uint128).max);
        minBounty = bound(minBounty, 0, 100e6);
        uint256 kBefore = usdc.balanceOf(keeper);
        vm.recordLogs();
        vm.prank(keeper);
        try adapter.liquidate(who, repayAmt, minBounty) returns (uint256 bounty, uint256) {
            ghostLiqs++;
            ghostBounty[keeper] += usdc.balanceOf(keeper) - kBefore;
            if (preHf >= 1e18) violHealthyLiq = true;
            _checkLiquidatedEvent(bounty);
        } catch {}
    }

    function liquidateDirectAnon(uint256 b) external {
        vm.prank(richAnon);
        try lend.liquidate(borrowers[b % 3], type(uint256).max, "") {
            violAnonDirect = true;
        } catch {}
    }

    function liquidateDirectKyc(uint256 b, uint256 repayAmt) external {
        address who = borrowers[b % 3];
        uint256 preHf = lend.healthFactor(who);
        vm.prank(kycLiq);
        try lend.liquidate(who, bound(repayAmt, 1e6, type(uint128).max), "") {
            if (preHf >= 1e18) violHealthyLiq = true;
        } catch {}
    }

    function _checkLiquidatedEvent(uint256 bounty) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 sig = keccak256("Liquidated(address,address,uint256,uint256,uint256)");
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(lend) || logs[i].topics[0] != sig) continue;
            (uint256 repaid, uint256 seized,) = abi.decode(logs[i].data, (uint256, uint256, uint256));
            if (bounty > repaid * lend.LB_BPS() / 10_000) violBountyCap = true;
            if (lend.collateralValue(seized) > repaid * (10_000 + lend.LB_BPS()) / 10_000 + 1) violSeizeBound = true;
        }
    }

    function borrowerAt(uint256 i) external view returns (address) { return borrowers[i]; }
    function keeperAt(uint256 i) external view returns (address) { return keepers[i]; }
}

import {Vm} from "forge-std/Vm.sol";

contract InvariantsTest is Test {
    Handler h;
    MockRWA rwa;
    MockUSDC usdc;
    MiniLend lend;
    SimVenue venue;
    SimAdapter adapter;

    function setUp() public {
        address issuer = makeAddr("issuer");
        address oracle = makeAddr("oracle");
        rwa = new MockRWA(issuer);
        usdc = new MockUSDC();
        lend = new MiniLend(rwa, usdc, oracle, 100e18, 1e18, 10_000e18, 1 days);
        venue = new SimVenue(rwa, usdc);
        adapter = new SimAdapter(lend, venue, 10_000);
        vm.startPrank(issuer);
        rwa.setFlags(address(lend), rwa.HOLDER());
        rwa.setFlags(address(venue), rwa.HOLDER());
        rwa.setFlags(address(adapter), rwa.HOLDER() | rwa.SWAP());
        rwa.mint(address(venue), 50_000e18);
        vm.stopPrank();
        usdc.mint(address(venue), 5_000_000e6);
        usdc.mint(address(this), 10_000_000e6);
        usdc.approve(address(lend), type(uint256).max);
        lend.supply(10_000_000e6);

        h = new Handler(rwa, usdc, lend, venue, adapter, issuer, oracle);
        targetContract(address(h));
    }

    /// I1 compliance: an address that is not HOLDER never has RWA (keepers, rich anon, PoolManager stand-in 0xdead)
    function invariant_I1_noNonHolderHoldsRwa() public view {
        for (uint256 i; i < 3; i++) assertEq(rwa.balanceOf(h.keeperAt(i)), 0);
        assertEq(rwa.balanceOf(h.richAnon()), 0);
        assertEq(rwa.balanceOf(address(0xdead)), 0);
    }

    /// I2 keepers only ever receive USDC, and exactly the bounties the adapter reported
    function invariant_I2_keepersOnlyUsdc() public view {
        for (uint256 i; i < 3; i++) {
            address k = h.keeperAt(i);
            assertEq(usdc.balanceOf(k), h.ghostBounty(k));
        }
    }

    /// I3 accounting / solvency identity + collateral conservation
    function invariant_I3_accounting() public view {
        assertEq(usdc.balanceOf(address(lend)) + lend.totalDebt(), lend.totalSupplyAssets());
        uint256 sumC;
        uint256 sumD;
        for (uint256 i; i < 3; i++) {
            (uint256 c, uint256 d) = lend.positions(h.borrowerAt(i));
            (sumC, sumD) = (sumC + c, sumD + d);
        }
        assertEq(rwa.balanceOf(address(lend)), lend.totalCollateral());
        assertEq(sumC, lend.totalCollateral());
        assertEq(sumD, lend.totalDebt());
    }

    /// I4 bounty <= repaid * LB and borrower loss <= repaid * (1 + LB) at NAV
    function invariant_I4_bountyAndLossBounds() public view {
        assertFalse(h.violBountyCap());
        assertFalse(h.violSeizeBound());
    }

    /// I5 only unhealthy positions are liquidated; non-allowlisted callers can never liquidate directly
    function invariant_I5_liquidationGating() public view {
        assertFalse(h.violHealthyLiq());
        assertFalse(h.violAnonDirect());
    }

    /// I6 adapter is stateless: never holds RWA or USDC between transactions
    function invariant_I6_adapterStateless() public view {
        assertEq(rwa.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(adapter)), 0);
    }

    function afterInvariant() public {
        // accumulate across runs (process env survives run resets) to prove liquidations were exercised
        uint256 liqs = vm.envOr("GHOST_LIQS", uint256(0)) + h.ghostLiqs();
        uint256 runsWithBadDebt = vm.envOr("GHOST_BADDEBT_RUNS", uint256(0)) + (lend.totalBadDebt() > 0 ? 1 : 0);
        vm.setEnv("GHOST_LIQS", vm.toString(liqs));
        vm.setEnv("GHOST_BADDEBT_RUNS", vm.toString(runsWithBadDebt));
        console2.log("cumulative adapter liquidations:", liqs);
        console2.log("cumulative runs with realised bad debt:", runsWithBadDebt);
    }
}

import {console2} from "forge-std/console2.sol";

contract HandlerSmokeTest is InvariantsTest {
    function test_smoke() public {
        Handler hh = Handler(h);
        hh.deposit(0, 1_000e18);
        hh.borrow(0, 100);
        (uint256 c, uint256 d) = lend.positions(hh.borrowerAt(0));
        console2.log("c,d", c, d);
        hh.moveNav(-1500, 0);
        console2.log("hf", lend.healthFactor(hh.borrowerAt(0)));
        hh.liquidateViaAdapter(0, 0, type(uint256).max, 0);
        console2.log("liqs", hh.ghostLiqs());
    }
}
