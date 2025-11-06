// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Cells View Helper (minimal, range-paginated)
/// @notice One-shot views for Cells/Cell state to minimize RPC overhead for UIs.
contract CellsViewHelper {
    /// -----------------------------------------------------------------------
    /// Config
    /// -----------------------------------------------------------------------
    address constant CELLS = 0x000000000022Edf13B917B80B4c0B52fab2eC902;

    // Fixed token set in UI-preferred order
    uint256 constant NUM_TOKENS = 9;
    address constant T_ETH = address(0);
    address constant T_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant T_USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant T_WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant T_wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant T_rETH = 0xae78736Cd615f374D3085123A210448E74Fc6393;
    address constant T_ENS = 0xC18360217D8F7Ab5e7c516566761Ea12Ce7F9D72;
    address constant T_LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;
    address constant T_PEPE = 0x6982508145454Ce325dDbE47a25d4ec3d2311933;

    uint8 constant D_ETH = 18;
    uint8 constant D_USDC = 6;
    uint8 constant D_USDT = 6;
    uint8 constant D_WBTC = 8;
    uint8 constant D_wstETH = 18;
    uint8 constant D_rETH = 18;
    uint8 constant D_ENS = 18;
    uint8 constant D_LINK = 18;
    uint8 constant D_PEPE = 18;

    // Roles
    uint8 constant ROLE_OWNER0 = 0;
    uint8 constant ROLE_OWNER1 = 1;
    uint8 constant ROLE_GUARD = 3; // UI label: "owner3"
    uint8 constant ROLE_NONE = 255;

    // Selectors
    bytes4 constant ERC20_BALANCE_OF = 0x70a08231; // balanceOf(address)
    bytes4 constant CELL_OWNERS = bytes4(keccak256("owners(uint256)"));
    bytes4 constant CELL_ALLOWANCE = bytes4(keccak256("allowance(address,address)"));
    bytes4 constant CELLS_COUNT = bytes4(keccak256("getCellCount()"));
    bytes4 constant CELLS_AT = bytes4(keccak256("cells(uint256)"));

    /// -----------------------------------------------------------------------
    /// Types
    /// -----------------------------------------------------------------------

    struct CellBasic {
        address cell;
        address[3] owners;
        uint256[NUM_TOKENS] balances; // index 0 is ETH
    }

    struct UserCellState {
        address cell;
        uint8 role; // 0,1,3
        uint256[NUM_TOKENS] balances; // Cell's balances
        uint256[NUM_TOKENS] allowanceToUser; // allowance(token, user)
        uint256[NUM_TOKENS] allowanceToOtherOwner; // allowance(token, other 1/2 owner). Zero if guardian.
    }

    /// -----------------------------------------------------------------------
    /// Token meta (for correct decimal handling client-side)
    /// -----------------------------------------------------------------------

    function getTokenList()
        external
        pure
        returns (address[NUM_TOKENS] memory addrs, uint8[NUM_TOKENS] memory decs)
    {
        addrs[0] = T_ETH;
        decs[0] = D_ETH;
        addrs[1] = T_USDC;
        decs[1] = D_USDC;
        addrs[2] = T_USDT;
        decs[2] = D_USDT;
        addrs[3] = T_WBTC;
        decs[3] = D_WBTC;
        addrs[4] = T_wstETH;
        decs[4] = D_wstETH;
        addrs[5] = T_rETH;
        decs[5] = D_rETH;
        addrs[6] = T_ENS;
        decs[6] = D_ENS;
        addrs[7] = T_LINK;
        decs[7] = D_LINK;
        addrs[8] = T_PEPE;
        decs[8] = D_PEPE;
    }

    /// -----------------------------------------------------------------------
    /// Global snapshots (owners + balances) with pagination
    /// -----------------------------------------------------------------------

    function getCellsStateRange(uint256 start, uint256 count)
        public
        view
        returns (CellBasic[] memory out)
    {
        (uint256 s, uint256 n) = _boundedRange(start, count);
        out = new CellBasic[](n);

        for (uint256 i; i != n;) {
            address cell = _getCellAt(s + i);

            address[3] memory os = _owners3(cell);
            uint256[NUM_TOKENS] memory bals = _balancesOf(cell);

            out[i] = CellBasic({cell: cell, owners: os, balances: bals});
            unchecked {
                ++i;
            }
        }
    }

    function getRecentCellsState(uint256 maxCount) external view returns (CellBasic[] memory out) {
        uint256 total = _getCellCount();
        if (maxCount == 0) return out;
        uint256 n = total > maxCount ? maxCount : total;
        uint256 start = total - n;
        return getCellsStateRange(start, n);
    }

    /// -----------------------------------------------------------------------
    /// Per-user one-shot state with pagination
    /// -----------------------------------------------------------------------

    function getUserCellsStateRange(address user, uint256 start, uint256 count)
        public
        view
        returns (UserCellState[] memory out)
    {
        (uint256 s, uint256 n) = _boundedRange(start, count);
        if (n == 0) return out;

        // Pass 1: collect matches (avoid re-reading same indices in a second _match call)
        address[] memory matched = new address[](n);
        uint8[] memory roles = new uint8[](n);
        uint256 m;

        for (uint256 i; i != n;) {
            address cell = _getCellAt(s + i);
            uint8 roleIdx = _roleInCell(cell, user);
            if (roleIdx != ROLE_NONE) {
                matched[m] = cell;
                roles[m] = roleIdx;
                unchecked {
                    ++m;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (m == 0) return out;

        // Pass 2: build user state
        out = new UserCellState[](m);
        for (uint256 j; j != m;) {
            address cell = matched[j];
            uint8 roleIdx = roles[j];

            address[3] memory os = _owners3(cell);
            uint8 role = roleIdx < 2 ? roleIdx : ROLE_GUARD;

            uint256[NUM_TOKENS] memory bals = _balancesOf(cell);

            uint256[NUM_TOKENS] memory toUser = _allowancesAll(cell, user);

            uint256[NUM_TOKENS] memory toOther;
            if (roleIdx < 2) {
                address other = os[roleIdx ^ 1];
                toOther = _allowancesAll(cell, other);
            }

            out[j] = UserCellState({
                cell: cell,
                role: role,
                balances: bals,
                allowanceToUser: toUser,
                allowanceToOtherOwner: toOther
            });
            unchecked {
                ++j;
            }
        }
    }

    function getRecentUserCellsState(address user, uint256 maxCount)
        external
        view
        returns (UserCellState[] memory out)
    {
        uint256 total = _getCellCount();
        if (maxCount == 0) return out;
        uint256 n = total > maxCount ? maxCount : total;
        uint256 start = total - n;
        return getUserCellsStateRange(user, start, n);
    }

    /// -----------------------------------------------------------------------
    /// Internals: bounds, owners, balances, allowances
    /// -----------------------------------------------------------------------

    function _boundedRange(uint256 start, uint256 count)
        internal
        view
        returns (uint256 s, uint256 n)
    {
        uint256 total = _getCellCount();
        if (start >= total || count == 0) return (0, 0);
        s = start;
        uint256 end = start + count;
        if (end > total) end = total;
        n = end - start;
    }

    function _getCellCount() internal view returns (uint256 count) {
        (bool ok, bytes memory data) = CELLS.staticcall(abi.encodeWithSelector(CELLS_COUNT));
        if (ok && data.length >= 32) count = abi.decode(data, (uint256));
    }

    function _getCellAt(uint256 idx) internal view returns (address cell) {
        (bool ok, bytes memory data) = CELLS.staticcall(abi.encodeWithSelector(CELLS_AT, idx));
        if (ok && data.length >= 32) cell = abi.decode(data, (address));
    }

    function _ownerAt(address cell, uint256 slot) internal view returns (address o) {
        (bool ok, bytes memory data) = cell.staticcall(abi.encodeWithSelector(CELL_OWNERS, slot));
        if (ok && data.length >= 32) o = abi.decode(data, (address));
    }

    function _owners3(address cell) internal view returns (address[3] memory os) {
        os[0] = _ownerAt(cell, 0);
        os[1] = _ownerAt(cell, 1);
        os[2] = _ownerAt(cell, 2);
    }

    /// @dev returns 0/1/2 if in cell (owner0/owner1/guardian), else 255.
    function _roleInCell(address cell, address user) internal view returns (uint8 r) {
        address o0 = _ownerAt(cell, 0);
        if (user == o0) return ROLE_OWNER0;
        address o1 = _ownerAt(cell, 1);
        if (user == o1) return ROLE_OWNER1;
        address og = _ownerAt(cell, 2);
        if (user == og) return 2; // guardian => mapped to ROLE_GUARD by caller
        return ROLE_NONE;
    }

    function _balancesOf(address cell) internal view returns (uint256[NUM_TOKENS] memory b) {
        b[0] = cell.balance; // ETH
        b[1] = _erc20Bal(T_USDC, cell);
        b[2] = _erc20Bal(T_USDT, cell);
        b[3] = _erc20Bal(T_WBTC, cell);
        b[4] = _erc20Bal(T_wstETH, cell);
        b[5] = _erc20Bal(T_rETH, cell);
        b[6] = _erc20Bal(T_ENS, cell);
        b[7] = _erc20Bal(T_LINK, cell);
        b[8] = _erc20Bal(T_PEPE, cell);
    }

    function _allowancesAll(address cell, address spender)
        internal
        view
        returns (uint256[NUM_TOKENS] memory a)
    {
        a[0] = _cellAllowance(cell, T_ETH, spender);
        a[1] = _cellAllowance(cell, T_USDC, spender);
        a[2] = _cellAllowance(cell, T_USDT, spender);
        a[3] = _cellAllowance(cell, T_WBTC, spender);
        a[4] = _cellAllowance(cell, T_wstETH, spender);
        a[5] = _cellAllowance(cell, T_rETH, spender);
        a[6] = _cellAllowance(cell, T_ENS, spender);
        a[7] = _cellAllowance(cell, T_LINK, spender);
        a[8] = _cellAllowance(cell, T_PEPE, spender);
    }

    function _erc20Bal(address token, address account) internal view returns (uint256 bal) {
        if (token == address(0)) return account.balance;
        (bool ok, bytes memory data) =
            token.staticcall(abi.encodeWithSelector(ERC20_BALANCE_OF, account));
        if (ok && data.length >= 32) bal = abi.decode(data, (uint256));
    }

    function _cellAllowance(address cell, address token, address spender)
        internal
        view
        returns (uint256 amt)
    {
        (bool ok, bytes memory data) =
            cell.staticcall(abi.encodeWithSelector(CELL_ALLOWANCE, token, spender));
        if (ok && data.length >= 32) amt = abi.decode(data, (uint256));
    }
}
