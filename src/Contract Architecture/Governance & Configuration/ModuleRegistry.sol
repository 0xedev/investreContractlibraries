// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title ModuleRegistry
 * @notice Registry of whitelisted modules that ActionExecutor can call.
 */
contract ModuleRegistry {
    mapping(address => bool) public modules;

    event ModuleRegistered(address indexed module);
    event ModuleRemoved(address indexed module);

    function registerModule(address module) external {
        require(!modules[module], "ModuleRegistry: already registered");
        modules[module] = true;
        emit ModuleRegistered(module);
    }

    function removeModule(address module) external {
        require(modules[module], "ModuleRegistry: not registered");
        modules[module] = false;
        emit ModuleRemoved(module);
    }

    function isModule(address module) external view returns (bool) {
        return modules[module];
    }
}
