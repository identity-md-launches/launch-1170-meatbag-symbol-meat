// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";
import {IIntake} from "../../src/MeatbagGame.sol";

/// @notice A stand-in for the IMD Intake: records the request, pulls the price, and can call the stored
/// callback from its own address under the oracle writer's 200,000 gas stipend.
contract MockIntake is IIntake {
    struct Stored {
        bytes32 action;
        bytes body;
        address target;
        bytes4 selector;
        address asset;
        uint256 amount;
    }

    error ActionNotSold();
    error WrongAmount(uint256 expected, uint256 got);

    uint256 public count;
    mapping(bytes32 => Stored) public requests;
    bytes32 public lastRequestId;
    bytes public lastBody;
    /// @notice What `priceOf` answers for every action in every asset. Defaults to the live 0.5 IMD.
    uint256 public price = 0.5 ether;
    /// @notice When set, `request` reverts `ActionNotSold`: the action was retired or is no longer sold.
    bool public refusing;

    function setPrice(uint256 price_) external {
        price = price_;
    }

    function setRefusing(bool refusing_) external {
        refusing = refusing_;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function request(bytes32 action, bytes calldata body, Callback calldata callback, address asset, uint256 amount)
        external
        payable
        returns (bytes32 requestId)
    {
        if (refusing || asset == address(0)) revert ActionNotSold();
        if (amount != price) revert WrongAmount(price, amount);
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
        requestId = keccak256(abi.encode("intake", ++count));
        requests[requestId] = Stored(action, body, callback.target, callback.selector, asset, amount);
        lastRequestId = requestId;
        lastBody = body;
    }

    /// @notice Delivers an answer the way the writer does: from this address, under 200,000 gas.
    function deliver(bytes32 requestId, OracleAttestation.Attestation memory a, bytes memory signature)
        external
        returns (bool ok)
    {
        Stored memory s = requests[requestId];
        (ok,) = s.target.call{gas: 200_000}(abi.encodeWithSelector(s.selector, requestId, a, signature));
    }

    /// @notice Delivers to an explicit target, for ids this intake never issued. Bubbles the revert.
    function deliverTo(
        address target,
        bytes4 selector,
        bytes32 requestId,
        OracleAttestation.Attestation memory a,
        bytes memory signature
    ) external {
        (bool ok, bytes memory ret) = target.call(abi.encodeWithSelector(selector, requestId, a, signature));
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
    }
}
