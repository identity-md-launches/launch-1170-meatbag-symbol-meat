// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {MeatbagGame} from "../src/MeatbagGame.sol";
import {MeatbagHerald} from "../src/MeatbagHerald.sol";
import {MockIntake} from "./mocks/MockIntake.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title The conformance test the oracle-consumer skill delivers, pointed at MeatbagGame
/// @notice Ties the game to what the oracle actually signs: the protocol's vector values, digest and
/// signature. The game is deployed at the vector's address with the vector's signer, trusting a mock
/// intake. `IntakeDelivery` is not used (the game is a same-chain consumer), so the delivered test
/// drives the mock intake instead.
contract OracleConsumerConformanceTest is Test {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    MockIntake intake;
    MockERC20 imd;
    MeatbagHerald herald;
    MeatbagGame consumer;
    address keeper = address(0xC0FFEE);
    address alice = address(0xA1);

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        intake = new MockIntake();
        imd = new MockERC20("IMD", "IMD", 10 ether);
        deployConsumer();
        imd.transfer(keeper, 5 ether);
        vm.prank(keeper);
        imd.approve(address(consumer), type(uint256).max);
        vm.deal(alice, 1 ether);
    }

    /// @dev The game at the vector's address, trusting `caller()`, with `SIGNER` as its oracle signer.
    function deployConsumer() internal {
        herald = new MeatbagHerald(VECTOR_CONSUMER);
        bytes memory code =
            abi.encodePacked(type(MeatbagGame).creationCode, abi.encode(herald, caller(), address(imd), SIGNER));
        vm.etch(VECTOR_CONSUMER, code);
        (bool built, bytes memory runtime) = VECTOR_CONSUMER.call("");
        require(built, "constructor reverted");
        vm.etch(VECTOR_CONSUMER, runtime);
        consumer = MeatbagGame(payable(VECTOR_CONSUMER));
        // The etch trick runs the constructor without CREATE, so the immutables are already in the runtime
        // but the constructor's storage writes happened in place: check the ones the tests rely on.
        assertEq(consumer.oracleSigner(), SIGNER);
        assertEq(consumer.INTAKE(), caller());
    }

    function caller() internal view returns (address) {
        return address(intake);
    }

    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    /// @dev Opens a round, closes it and asks, so the game has one pending request to answer.
    function pendingRequest() internal returns (bytes32 intakeId) {
        vm.prank(alice);
        consumer.enter{value: 0.001 ether}("I am a person and my feet are cold");
        vm.warp((consumer.today() + 1) * 1 days + 1);
        vm.prank(keeper);
        intakeId = consumer.judge();
        vm.warp(ISSUED_AT + 60);
    }

    /// @notice The digest the game verifies is the one the oracle signs.
    function test_digestMatchesTheProtocol() public view {
        assertEq(
            consumer.attestationDigest(vector()),
            VECTOR_DIGEST,
            "struct, type string or domain differs from the protocol's"
        );
    }

    /// @notice The callback's selector is the one the intake calls.
    function test_callbackSelectorIsCanonical() public view {
        assertEq(consumer.onOracleResult.selector, bytes4(keccak256(bytes(CALLBACK))));
    }

    /// @notice The protocol's own signature, delivered the way the writer delivers it, is accepted. The
    /// vector is a bytes32[] answer from a panel of five, so the game records it as a hung jury rather
    /// than a verdict, but it verified and consumed the attestation under the 200,000 gas stipend.
    function test_acceptsTheProtocolSignatureAsDelivered() public {
        bytes32 intakeId = pendingRequest();
        bool called = intake.deliver(intakeId, vector(), VECTOR_SIGNATURE);
        assertTrue(called, "the callback did not run to the end under the 200,000 gas stipend");
        assertTrue(consumer.consumed(vector().requestId));
        assertEq(uint8(consumer.round(consumer.roundDays(0)).status), uint8(MeatbagGame.Status.Hung));
    }

    /// @notice A fresh signature from the same key verifies too, and a proper uint256 answer settles.
    function test_acceptsAFreshSignatureFromTheVectorKey() public {
        bytes32 intakeId = pendingRequest();
        OracleAttestation.Attestation memory a = vector();
        a.requestId = keccak256("another request");
        a.answerType = OracleAttestation.ANSWER_UINT256;
        a.answer = abi.encode(uint256(0));
        a.panelSize = 7;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        vm.prank(caller());
        consumer.onOracleResult(intakeId, a, abi.encodePacked(r, s, v));
        assertTrue(consumer.consumed(a.requestId));
        assertEq(uint8(consumer.round(consumer.roundDays(0)).status), uint8(MeatbagGame.Status.Settled));
        assertGt(consumer.claimable(alice), 0);
    }
}
