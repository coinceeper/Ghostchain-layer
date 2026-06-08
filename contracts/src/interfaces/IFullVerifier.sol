// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IFullVerifier
/// @notice Typed interface for full generated proof verifier contracts.
interface IFullVerifier {
    function verifyProof(bytes calldata proof, bytes calldata publicInputs) external view returns (bool);
    function verifyPlonkProof(bytes calldata proof, bytes calldata publicInputs) external view returns (bool);
    function verifyNullifierProof(bytes calldata proof, bytes calldata publicInputs) external view returns (bool);
}
