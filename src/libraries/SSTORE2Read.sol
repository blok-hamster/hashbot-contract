// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice SSTORE2 — store data as contract code. Writer builds initcode that
///         `RETURN`s the appended payload, so the deployed runtime code IS the data.
///         This is the standard Solady-style layout. Reader slices via extcodecopy.
library SSTORE2Read {
    /// @notice Deploy `data` as a contract's runtime code. Returns the SSTORE2 address.
    function write(bytes memory data) internal returns (address deployed) {
        // Initcode: 63 <uint32 len> 80600e6000396000f3 <data>
        //   PUSH4 len / DUP1 / PUSH1 0x0e / PUSH1 0x00 / CODECOPY / PUSH1 0x00 / RETURN
        bytes memory initcode = abi.encodePacked(
            hex"63",
            uint32(data.length),
            hex"80600e6000396000f3",
            data
        );
        // solhint-disable-next-line no-inline-assembly
        assembly {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(deployed != address(0), "SSTORE2: create failed");
    }

    /// @notice Read `length` bytes starting at `offset` from the contract at `addr`.
    function read(address addr, uint256 offset, uint256 length)
        internal
        view
        returns (bytes memory data)
    {
        require(length <= 24576, "SSTORE2: too large");
        data = new bytes(length);
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // extcodecopy(destOffset, addr, codeOffset, length)
            extcodecopy(addr, add(data, 0x20), offset, length)
        }
    }
}
