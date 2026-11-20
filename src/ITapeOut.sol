// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice The TapeOut processor factory. It says whether an address is a processor it created.
interface IProcessorFactory {
    function isCPU(address) external view returns (bool);
}

/// @notice A TapeOut processor: an ERC-721 contract whose tokens are circuits.
/// Return types match the live X Layer contracts (evidence/2026-11-20-preflight.md, section 2).
interface IProcessor {
    /// @notice Run a circuit with no memory bits. Reverts for circuits that have memory.
    function eval(uint256 id, bytes calldata inputs) external view returns (bytes memory);

    /// @notice Run one tick of a circuit with memory bits. The caller supplies the memory.
    function step(uint256 id, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs);

    function circuitInfo(uint256 id)
        external
        view
        returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);

    function netlist(uint256 id) external view returns (bytes memory);

    /// @notice ERC-721 owner of circuit `id`.
    function ownerOf(uint256 id) external view returns (address);
}
