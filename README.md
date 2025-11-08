# CELLS – 2/2 Multisig Protocol

Cell Wallet (“Cells”) is an opinionated 2-of-2 multisig smart contract wallet on Ethereum,  
with an optional soft guardian role for 2-of-3 recovery. It’s designed for:

- **Simplicity**
- **Security**
- **Sovereignty**

---

## Links

- **dApp:** https://cellwall.eth.limo  
- **Protocol Contract:** [`0x000000000022Edf13B917B80B4c0B52fab2eC902`](https://etherscan.io/address/0x000000000022edf13b917b80b4c0b52fab2ec902#code)  
- **Lite (minimal proxy):** [`0x000000000022fe09b19508Ceeb97FBEb41B66d0F`](https://etherscan.io/address/0x000000000022fe09b19508Ceeb97FBEb41B66d0F#code) 
- **GitHub:** https://github.com/z0r0z/cells  

---

## 0. Introduction

Cell Wallet is a smart contract wallet where:

- Every wallet (“Cell”) is controlled by **exactly two owners**.
- **Both owners must approve** every transaction (2-of-2), unless:
  - The transaction is covered by an **allowance**, or
  - The transaction uses a **permit**.
- An optional **guardian** can participate in approvals but has limited powers.

The goal is to keep a tight, predictable security model while still enabling smooth daily usage and recoverability.

---

## 1. Core Concepts

### 1.1 2/2 Multisig

- A Cell requires **both owners** to approve any transaction.
- There is **no hierarchy** between owners:
  - Both have equal power.
  - There’s no single point of failure.
- This avoids the complexity of threshold signatures while maintaining strong guarantees.

### 1.2 Sorted Ownership

- Owners are **automatically sorted by address**: `owner0 < owner1`.
- This ensures deterministic behavior and removes any ambiguity about owner ordering.

### 1.3 Guardian Role (Optional)

- A third address with **limited powers**:
  - Can **initiate** and **co-approve** transactions.
  - **Cannot** directly set allowances or permits (those require 2/2 owner consensus).
- Ideal for:
  - Recovery scenarios.
  - Trusted third-party assistance.

---

## 2. Key Features

- **Chat Messages**  
  On-chain communication between owners. Discuss transactions, leave notes, coordinate approvals.

- **Allowances**  
  One owner can grant the other spending permissions.  
  Once set, these **do not require 2/2** for spending within pre-approved limits.

- **Permits**  
  Reusable execution authorizations. Allow repeated actions without re-approving each time.

- **Batch Execute**  
  Execute multiple transactions atomically.  
  Either **all succeed** or **all revert**.

- **EIP-712 Signing**  
  Approvals can be signed offline using typed data.  
  Owners don’t need to be online simultaneously.

- **Ownership Transfer**  
  Each owner can transfer their “slot” to a new address.  
  Sorted ownership is preserved automatically.

---

## 3. Technical Details

### 3.1 Contract Architecture (High Level)

```solidity
// Core state variables
address[3] public owners;     // [owner0, owner1, guardian]
string[] public messages;     // On-chain chat
mapping(bytes32 => address) public approved;  // Pending approvals
mapping(address => mapping(address => uint256)) public allowance;
````

* `owners[0]` – Owner 0 (lower address)
* `owners[1]` – Owner 1 (higher address)
* `owners[2]` – Guardian (optional)
* `messages` – Simple on-chain chat log
* `approved` – Tracks which address has approved which transaction hash
* `allowance` – Token allowances between owners

### 3.2 Transaction Flow

1. **Initiate**
   First owner (or guardian, where allowed) calls `execute()` with transaction parameters.

2. **Hash**
   The transaction is hashed and stored with the first approver.

3. **Approve**
   Second approver (owner or guardian, depending on action) calls `execute()` with the **same parameters**.

4. **Execute**
   On matching approvals, the transaction executes atomically.

### 3.3 Hashing Mechanism

Transactions are identified by their **content hash**:

```solidity
bytes32 hash = keccak256(abi.encodePacked(
    this.execute.selector,
    to,
    value,
    keccak256(data),
    nonce
));
```

* `to` – Target address
* `value` – ETH value
* `data` – Calldata payload
* `nonce` – Uniquely identifies the transaction instance

---

## 4. Special Permissions

Different roles have access to different actions:

| Action                  | Owner 0/1       | Guardian        |
| ----------------------- | --------------- | --------------- |
| Initiate transaction    | ✓               | ✓               |
| Approve & execute       | ✓               | ✓               |
| Send chat message       | ✓               | ✓               |
| Transfer ownership      | ✓               | ✗               |
| Set allowances          | ✓               | ✗               |
| Cancel pending approval | ✓ (if approver) | ✓ (if approver) |

---

## 5. Using the dApp

### 5.1 Getting Started

1. Go to **[https://cellwall.eth.limo](https://cellwall.eth.limo)**
2. Connect your Web3 wallet (Rainbow, MetaMask, Coinbase, etc.)
3. Create a new Cell or connect to an existing one.

### 5.2 Interface Overview

The interface visually mirrors the 2-of-2 structure.

* **Black Half (Owner 0)**

  * Shows Owner 0’s address, status, and pending transaction count.

* **White Half (Owner 1)**

  * Shows Owner 1’s address, status, and pending transaction count.

* **Chat Drawer**

  * Bottom drawer for:

    * Messages
    * Transactions
    * Allowances
    * Permits

### 5.3 Transaction Types

* **SEND** – Transfer ETH or ERC-20 tokens
* **CONTRACT** – Call arbitrary smart contract functions
* **ALLOWANCE** – Grant spending permission to the other owner
* **PERMIT** – Create reusable execution permissions
* **GUARDIAN** – Set or update the guardian address
* **TRANSFER** – Transfer your owner slot to another address

---

## 6. Security Considerations

### 6.1 Best Practices

* Use **hardware wallets** for owner accounts.
* Store owner keys in **separate physical / logical locations**.
* Choose the **guardian carefully**:

  * They can initiate and co-approve in some flows.
  * They can’t change allowances or permits on their own.
* Always use **unique nonces** for each transaction.
* Confirm transaction **hashes** and parameters before you approve.

### 6.2 Recovery Scenarios

* **Lost one owner key**
  Remaining owner + guardian can execute an ownership transfer to a new address.

* **Lost guardian key**
  Both owners can update the guardian address.

* **Lost both owner keys**
  Funds are permanently locked; the guardian alone cannot recover funds.
  → Keep secure backups of owner keys.

---

## 7. Gas Optimization

Cells uses several patterns to reduce gas usage:

* **Transient storage** for reentrancy guards (EIP-1153)
* **Transaction content hashing** for compact storage
* **Inline assembly** for critical operations
* **Batch operations** to amortize base costs

Example optimized reentrancy guard:

```solidity
// Optimized reentrancy guard using transient storage
modifier nonReentrant() {
    assembly {
        if tload(REENTRANCY_GUARD_SLOT) {
            mstore(0x00, 0xab143c06)
            revert(0x1c, 0x04)
        }
        tstore(REENTRANCY_GUARD_SLOT, address())
    }
    _;
    assembly { tstore(REENTRANCY_GUARD_SLOT, 0) }
}
```

---

## 8. Examples

### 8.1 Creating a Cell

```solidity
// Via Cells contract
cells.createCell(
    owner0,        // First owner (will be sorted)
    owner1,        // Second owner
    guardian,      // Optional guardian (or address(0))
    salt,          // Random salt for CREATE2
    initCalls      // Initial setup calls
);
```

### 8.2 Executing a Transaction

```solidity
// First approval
cell.execute(
    to,            // Target address
    value,         // ETH amount
    data,          // Call data
    nonce          // Unique nonce
);

// Second approval (same parameters)
cell.execute(to, value, data, nonce);
// Transaction executes automatically on second approval
```

### 8.3 Setting Allowance

```solidity
// Allow other owner to spend 10 USDC
cell.setAllowance(
    address(0),    // Spender (0 = other owner)
    USDC_ADDRESS,  // Token address
    10e6           // Amount (with decimals)
);
```

---

## 9. Advanced Features

### 9.1 Multicall

Atomically execute multiple calls to the Cell contract:

```solidity
bytes;
calls[0] = abi.encodeCall(cell.chat, "Sending funds");
calls[1] = abi.encodeCall(cell.execute, (to, value, data, nonce));

cell.multicall(calls);
```

### 9.2 Delegate Execution

Execute code in the Cell’s context (e.g., for modules / upgrades):

```solidity
cell.delegateExecute(
    implementationContract,
    delegateCallData,
    nonce
);
```

### 9.3 EIP-712 Batch Signatures

Approve a batch of transactions using EIP-712 signatures:

```solidity
cell.batchExecuteWithSig(
    tos,           // Target addresses array
    values,        // Values array
    datas,         // Call data array
    nonce,         // Batch nonce
    deadline,      // Expiry timestamp
    v, r, s        // Signature components
);
```

---

## License

Cell Wallet · 2/2 Multisig Protocol
**MIT License**