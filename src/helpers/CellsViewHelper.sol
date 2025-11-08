// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/// @title Cells View Helper (maximal, user-scoped, one-shot)
/// @notice One-shot views for Cells/Cell state + owner ENS + chat tails to minimize RPC overhead for UIs.
contract CellsViewHelper {
    /// -----------------------------------------------------------------------
    /// Config
    /// -----------------------------------------------------------------------
    // Original Cells factory
    address constant CELLS = 0x000000000022Edf13B917B80B4c0B52fab2eC902;

    // New CellsLite factory (minimal proxy variant)
    address constant CELLS_LITE = 0x000000000022fe09b19508Ceeb97FBEb41B66d0F;

    // External helper for reverse ENS (must return "" for no-name, never revert)
    address constant CHECK_THE_CHAIN = 0x0000000000cDC1F8d393415455E382c30FBc0a84;

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

    // Chat selectors on Cell
    bytes4 constant CELL_CHAT_COUNT = bytes4(keccak256("getChatCount()"));
    bytes4 constant CELL_MESSAGES = bytes4(keccak256("messages(uint256)"));

    // ENS helper
    bytes4 constant WHAT_IS_THE_NAME_OF = bytes4(keccak256("whatIsTheNameOf(address)"));

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
        address[3] owners; // included for completeness/compatibility
        uint256[NUM_TOKENS] balances; // Cell's balances
        uint256[NUM_TOKENS] allowanceToUser; // allowance(token, user)
        uint256[NUM_TOKENS] allowanceToOtherOwner; // allowance(token, other 1/2 owner). Zero if guardian.
    }

    /// @dev Maximal UI payload per cell for a connected user
    struct CellDeep {
        address cell;
        address[3] owners; // owner0, owner1, guardian
        string[3] ownerENS; // reverse ENS for owners ("" if none or includeENS=false)
        uint8 userRole; // 0,1,3 or 255
        uint256[NUM_TOKENS] balances; // cell token balances
        uint256[NUM_TOKENS] allowanceToUser;
        uint256[NUM_TOKENS] allowanceToOtherOwner;
        uint256 chatCount; // total message count
        string[] lastMessages; // tail, length <= maxChatTail (can be empty)
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
    /// Global snapshots (owners + balances) with pagination (back-compat)
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
    /// Per-user one-shot state (back-compat; includes owners)
    /// -----------------------------------------------------------------------

    function getUserCellsStateRange(address user, uint256 start, uint256 count)
        public
        view
        returns (UserCellState[] memory out)
    {
        (uint256 s, uint256 n) = _boundedRange(start, count);
        if (n == 0) return out;

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
                owners: os,
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
    /// Maximal per-user one-shot state (owners + ENS + balances + allowances + chat tail)
    /// -----------------------------------------------------------------------

    /// @notice Deep, user-scoped snapshot over [start .. start+count) of the logical Cells list
    ///         (CELLS first, then CELLS_LITE).
    /// @param user          The connected user to scope allowances/role to.
    /// @param start         Start logical index.
    /// @param count         Max number of indices to scan from start.
    /// @param maxChatTail   Tail length of messages to include per cell (0 to skip).
    /// @param includeENS    If true, resolves owner ENS with CheckTheChain (3 extra calls per cell).
    function getUserCellsDeepRange(
        address user,
        uint256 start,
        uint256 count,
        uint8 maxChatTail,
        bool includeENS
    ) public view returns (CellDeep[] memory out) {
        (uint256 s, uint256 n) = _boundedRange(start, count);
        if (n == 0) return out;

        // Pass 1: filter membership & cache role indices
        address[] memory matched = new address[](n);
        uint8[] memory roleIdxs = new uint8[](n);
        uint256 m;
        for (uint256 i; i != n;) {
            address cell = _getCellAt(s + i);
            uint8 r = _roleInCell(cell, user);
            if (r != ROLE_NONE) {
                matched[m] = cell;
                roleIdxs[m] = r;
                unchecked {
                    ++m;
                }
            }
            unchecked {
                ++i;
            }
        }
        if (m == 0) return out;

        // Pass 2: build full UI payload
        out = new CellDeep[](m);
        for (uint256 j; j != m;) {
            address cell = matched[j];
            uint8 roleIdx = roleIdxs[j];

            // Owners
            address[3] memory os = _owners3(cell);

            // ENS (explicitly initialize to empty strings if not included)
            string[3] memory ens;
            if (includeENS) {
                ens[0] = _ensName(os[0]);
                ens[1] = _ensName(os[1]);
                ens[2] = _ensName(os[2]);
            } else {
                ens[0] = "";
                ens[1] = "";
                ens[2] = "";
            }

            // Balances & allowances
            uint256[NUM_TOKENS] memory bals = _balancesOf(cell);
            uint256[NUM_TOKENS] memory toUser = _allowancesAll(cell, user);

            uint256[NUM_TOKENS] memory toOther;
            if (roleIdx < 2) {
                address other = os[roleIdx ^ 1];
                toOther = _allowancesAll(cell, other);
            }
            uint8 role = roleIdx < 2 ? roleIdx : ROLE_GUARD;

            // Chat tail (always initialize dynamic array)
            string[] memory tail;
            uint256 chatCount = _chatCount(cell);
            if (maxChatTail != 0 && chatCount != 0) {
                uint256 k = chatCount > maxChatTail ? uint256(maxChatTail) : chatCount;
                tail = new string[](k);
                uint256 startIdx = chatCount - k;
                for (uint256 t; t != k;) {
                    tail[t] = _messageAt(cell, startIdx + t);
                    unchecked {
                        ++t;
                    }
                }
            }

            // Assign
            CellDeep memory row;
            row.cell = cell;
            row.owners = os;
            row.ownerENS = ens;
            row.userRole = role;
            row.balances = bals;
            row.allowanceToUser = toUser;
            row.allowanceToOtherOwner = toOther;
            row.chatCount = chatCount;
            row.lastMessages = tail;

            out[j] = row;
            unchecked {
                ++j;
            }
        }
    }

    /// @notice Deep, user-scoped snapshot over the most recent logical cells.
    function getRecentUserCellsDeep(
        address user,
        uint256 maxCount,
        uint8 maxChatTail,
        bool includeENS
    ) external view returns (CellDeep[] memory out) {
        uint256 total = _getCellCount();
        if (maxCount == 0) return out;
        uint256 n = total > maxCount ? maxCount : total;
        uint256 start = total - n;
        return getUserCellsDeepRange(user, start, n, maxChatTail, includeENS);
    }

    /// -----------------------------------------------------------------------
    /// Small helpers for delta-refreshes & batched lookups
    /// -----------------------------------------------------------------------

    /// @notice Batched approved[] lookups so UI avoids N separate RPCs.
    function getApprovedBatch(address cell, bytes32[] calldata hashes)
        external
        view
        returns (address[] memory out)
    {
        out = new address[](hashes.length);
        for (uint256 i; i != hashes.length;) {
            (bool ok, bytes memory data) =
                cell.staticcall(abi.encodeWithSignature("approved(bytes32)", hashes[i]));
            if (ok && data.length >= 32) {
                out[i] = abi.decode(data, (address));
            }
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Get last N messages without re-pulling the world.
    function getRecentMessages(address cell, uint256 maxCount)
        external
        view
        returns (string[] memory out)
    {
        uint256 count = _chatCount(cell);
        if (count == 0 || maxCount == 0) return out;
        uint256 n = count > maxCount ? maxCount : count;
        uint256 start = count - n;
        out = _messagesRange(cell, start, n);
    }

    /// @notice Fetch a messages slice (for delta appends).
    function getMessagesRange(address cell, uint256 start, uint256 count)
        external
        view
        returns (string[] memory out)
    {
        uint256 len = _chatCount(cell);
        if (start >= len || count == 0) return out;
        uint256 end = start + count;
        if (end > len) end = len;
        uint256 n = end - start;
        out = _messagesRange(cell, start, n);
    }

    /// Optional passthrough (handy in UIs)
    function getCellsCount() external view returns (uint256) {
        return _getCellCount();
    }

    /// -----------------------------------------------------------------------
    /// Internals: bounds, owners, balances, allowances, chat, ENS
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

    /// @dev Total logical count across CELLS and CELLS_LITE.
    function _getCellCount() internal view returns (uint256 count) {
        uint256 c0 = _getCellsCountFrom(CELLS);
        uint256 c1 = _getCellsCountFrom(CELLS_LITE);
        count = c0 + c1;
    }

    function _getCellsCountFrom(address factory) internal view returns (uint256 count) {
        (bool ok, bytes memory data) = factory.staticcall(abi.encodeWithSelector(CELLS_COUNT));
        if (ok && data.length >= 32) {
            count = abi.decode(data, (uint256));
        }
    }

    /// @dev Maps a logical index into [CELLS cells..., CELLS_LITE cells...].
    function _getCellAt(uint256 idx) internal view returns (address cell) {
        uint256 mainCount = _getCellsCountFrom(CELLS);
        if (idx < mainCount) {
            cell = _getCellAtFrom(CELLS, idx);
        } else {
            uint256 liteIdx = idx - mainCount;
            cell = _getCellAtFrom(CELLS_LITE, liteIdx);
        }
    }

    function _getCellAtFrom(address factory, uint256 idx) internal view returns (address cell) {
        (bool ok, bytes memory data) = factory.staticcall(abi.encodeWithSelector(CELLS_AT, idx));
        if (ok && data.length >= 32) {
            cell = abi.decode(data, (address));
        }
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

    function _chatCount(address cell) internal view returns (uint256 cnt) {
        (bool ok, bytes memory data) = cell.staticcall(abi.encodeWithSelector(CELL_CHAT_COUNT));
        if (ok && data.length >= 32) cnt = abi.decode(data, (uint256));
    }

    function _messagesRange(address cell, uint256 start, uint256 n)
        internal
        view
        returns (string[] memory out)
    {
        out = new string[](n);
        for (uint256 i; i != n;) {
            out[i] = _messageAt(cell, start + i);
            unchecked {
                ++i;
            }
        }
    }

    function _messageAt(address cell, uint256 idx) internal view returns (string memory s) {
        (bool ok, bytes memory data) = cell.staticcall(abi.encodeWithSelector(CELL_MESSAGES, idx));
        if (!ok || data.length < 64) return "";
        try this._decodeString(data) returns (string memory t) {
            return t;
        } catch {
            return "";
        }
    }

    /// @dev Calls CheckTheChain.whatIsTheNameOf(user); returns "" on any failure.
    function _ensName(address user) internal view returns (string memory name) {
        if (user == address(0)) return "";
        (bool ok, bytes memory data) =
            CHECK_THE_CHAIN.staticcall(abi.encodeWithSelector(WHAT_IS_THE_NAME_OF, user));
        if (!ok || data.length < 64) return "";
        try this._decodeString(data) returns (string memory s) {
            return s;
        } catch {
            return "";
        }
    }

    /// @dev helper to permit try/catch on abi.decode (must be external)
    function _decodeString(bytes memory data) external pure returns (string memory s) {
        s = abi.decode(data, (string));
    }
}
