// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

// A simple mock ERC20 token for testing
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock Token", "MCK") {
        _mint(msg.sender, 1000 * 10**18); // Give creator 1000 tokens
    }
}

 data:application/json;base64,eyJuYW1lIjogIkN1cmF0ZWQgWW91VHViZSBORlQgIzAiLCAiZGVzY3JpcHRpb24iOiAiQSBjdXJhdGVkLCBzZXF1ZW50aWFsbHkgbWludGVkIE5GVCBmcm9tIGEgZ3Jvd2luZyBjb2xsZWN0aW9uLiIsICJpbWFnZSI6ICJodHRwczovL2ltZy55b3V0dWJlLmNvbS92aS85ZEhWc2Q0MjFDUS9ocWRlZmF1bHQuanBnIiwgImFuaW1hdGlvbl91cmwiOiAiaHR0cHM6Ly93d3cueW91dHViZS5jb20vZW1iZWQvOWRIVnNkNDIxQ1EifQ==
