# Engineering a Custom Layer-1 Blockchain From Scratch
### A Bare-Metal Go Development Guide for Software Engineers

This guide outlines the precise architectural steps, fundamental engineering concepts, and structural primitives required to design and implement a fully functional, distributed Layer-1 blockchain from scratch using **Go (Golang)**. 

---

## Phase 1: Cryptographic Primitives & Core Storage
Before constructing blocks, you must implement the cryptographic foundations that guarantee data integrity, identity management, and transaction authentication.

### 1. Hashing Engine (`crypto/sha256`)
* **Core Concept:** A one-way mathematical function transforming variable-length inputs into a fixed-length **32-byte (256-bit) array**. It must be deterministic and collision-resistant.
* **Execution Logic:** Because `sha256.Sum256()` strictly consumes a byte slice (`[]byte`), you must establish a reliable serialization strategy to flatten your data structs before feeding them into the hashing function.

### 2. Key Pairs & Addresses (`crypto/ecdsa`)
* **Core Concept:** Asymmetric cryptography replacing traditional identity models. A cryptographically secure random number serves as the **Private Key** (used to authorize/sign actions). An elliptic curve formula derives the **Public Key**, which is further truncated to form the network **Address**.

### 3. Digital Signatures
* **Core Concept:** Cryptographic verification confirming identity and operational payload payload preservation.
* **Execution Logic:** 
  * **Signing:** The transaction hash and Private Key are processed via `ecdsa.SignASN1()`, generating a signature byte slice.
  * **Verification:** Validator nodes consume the sender's Public Key, the payload hash, and the signature via `ecdsa.VerifyASN1()` to return a strict boolean validation.

---

## Phase 2: Core Domain Objects & Structural Schemas
Define your underlying data layers inside a core module folder (`/core`) to map your state and structural schemas cleanly.

### 1. The Transaction Struct
Represents an isolated, explicit modification request to the ledger's state.
* `Sender` (`string` or `[]byte` address)
* `Recipient` (`string` or `[]byte` address)
* `Amount` (`uint64`)
* `Signature` (`[]byte`)
* `Timestamp` (`int64` Unix time to enforce uniqueness for identical value transfers)

### 2. The Block Struct
The physical container bundling transaction arrays and cryptographically chaining them to historical entries.
* `Index` (`int` positioning, Genesis = 0)
* `Timestamp` (`int64`)
* `Transactions` (`[]Transaction`)
* `PrevHash` (`string` or `[]byte` link connecting back to the previous block's unique hash)
* `Hash` (`string` or `[]byte` current block identifier)
* `Nonce` (`int` loop counter for consensus computation)

### 3. The Blockchain Struct
The internal ledger representation. Managed in-memory during early stages as an append-only sequence slice: `[]Block`.

---

## Phase 3: Consensus Engine (Proof of Work & The Nonce Loop)
Regulates execution pacing and blocks spam vectors by enforcing structural mathematical boundaries prior to ledger insertion.

### 1. The Hashing & Mining Pipeline
To regulate entry production, you require a static global variable: `Difficulty`. If `Difficulty = 4`, the output hash string representation must begin with exactly four consecutive zeroes (`"0000"`).

### 2. Loop Execution Logic
1. Instantiate a new Block wrapper with current timestamps, target transaction slices, and the preceding block's hash.
2. Initialize `Nonce = 0`.
3. Open an infinite `for` loop:
   * Serialize the block metadata along with the active `Nonce` into a flat byte stream.
   * Calculate the `sha256.Sum256` fingerprint.
   * Evaluate the leading characters of the hash slice against the zero-prefix requirement (`hash[:difficulty]`).
   * **Success:** Set `Block.Hash` to the solved value, exit the loop, and append to the chain.
   * **Failure:** Increment `Nonce++` and repeat the computation.

---

## Phase 4: Mempool Buffer & Deterministic State Machine
Establishes execution rules and internal record-keeping parameters for processed balances.

### 1. The Mempool Staging Queue
A transient memory map (`map[string]Transaction`) residing inside the RAM of every distinct node. Unconfirmed transactions remain within this validation queue until a mining engine batches them into a consensus cycle.

### 2. The State Machine & Account Balance Model
Maintained as a thread-safe map layer: `var State map[string]uint64`. Execution transitions must follow a **pure function** design (`f(State, Tx) -> NewState`), entirely stripped of random number generation, external network input/output, or system variable lookups to prevent network de-synchronization.

### 3. Execution Pipeline Logic
When a newly mined block arrives:
1. Verify sender solvency: `if State[Tx.Sender] < (Tx.Amount + Tx.GasLimit * Tx.GasPrice)`. Reject instantly on failure.
2. Instantiate a `gasCounter` tracing the `GasLimit`. Deduct operational costs step-by-step from the counter during processing.
3. If `gasCounter < 0` occurs mid-computation, halt execution, discard all ledger mutations, but seize the max fee as a network penalty to mitigate DoS injection vectors.
4. On success, permanently modify state balances: `State[Tx.Sender] -= Tx.Amount`, `State[Tx.Recipient] += Tx.Amount`. Refresh the volatile mempool queue by pruning executed entries.

---

## Phase 5: P2P Gossip Networking Layer
Coordinates data synchronization, network presence, and data consistency across independent network listeners.

### 1. The Dual Net Architecture (`net`)
Every instance of your Go runtime must deploy two explicit network loops simultaneously using Go's `net` package:
* **The Listener Loop:** Hosts a dedicated background socket via `net.Listen("tcp", ":port")` to capture incoming node connections.
* **The Client Router:** Actively calls out via `net.Dial("tcp", "peer_address:port")` to established peers. Track all verified conduits safely in a mutex-guarded peer map.

### 2. Wire Protocol and Gossip Serialization
* **Envelope Pattern:** Wrap all network network operations within a standard layout consisting of a `MessageType` (string tag) and a raw byte `Payload`. Serialize data structures cleanly across TCP streams using `encoding/gob` or `encoding/json`.
* **Gossip Logic:** When handling a new block or transaction payload, verify your internal history cache first. If unseen, update local storage, then iterate over your active connection grid to stream the bytes forward, dropping recognized hashes immediately to eliminate network loops.

---

## Phase 6: Fork Resolution & Chain Reorganization
Manages concurrency conflicts and data divergence across remote geographic nodes.

### 1. Longest Chain Enforcement
If a remote node broadcasts an alternative history showcasing a higher cumulative proof of work (simplistically tracked as `peer.ChainHeight > len(myChain)`), the shorter path must be truncated and synchronized to match the global majority.

### 2. Reorg Implementation Steps
1. Pause native block production loops.
2. Traverse backward from the tip of your chain to discover the **Common Ancestor** where `myChain[i].Hash == peerChain[i].Hash`.
3. Roll back the local `State` map by looping backwards through transactions from the discarded fork blocks, executing reverse balance math to restore historical values.
4. Truncate your local chain slice back to the Common Ancestor index.
5. Append the peer's alternative blocks to your chain array.
6. Feed the newly imported blocks forward through the state machine execution loops to calculate the updated balance maps.
7. Return un-executed transactions back to the local `Mempool` queue to safeguard valid data.

---

## Recommended Project Directory Layout

```text
custom-blockchain/
├── go.mod          # Package definition and external dependencies
├── main.go         # Bootstrapper, flag parsing, and module runtime initialization
├── core/
│   ├── block.go        # Block schema configurations and serialization
│   ├── transaction.go  # Key creation, signing primitives, and tx schemas
│   ├── blockchain.go   # Chain list container and genesis configurations
│   └── state.go        # Account tracking and deterministic state execution
├── consensus/
│   └── pow.go          # Nonce loops, mining logic, and difficulty parameters
└── network/
    ├── server.go       # Listener/Dialer connections and reorg routers
    ├── protocol.go     # Message envelope definitions and bytes parsing
    └── mempool.go      # Memory storage pools and gossip cache trackers
```

---

## Practical Application Tasks (Learning Milestones)

Once your core L1 Go network is operational, you can test and run it through these target projects:

* **Command-Line Wallet App:** Build an independent terminal utility using asymmetric crypto to save private keys locally into JSON files, sign transactional data strings, and push raw payloads to your node's TCP mempool socket.
* **Local Block Explorer:** Construct a lightweight dashboard program that calls your Go node endpoints to read the `[]Block` array and `State` map, printing real-time mining metrics visually.
* **Decentralized Name Service (DNS):** Alter your transaction struct to include text key-value registers, allowing users to claim an un-alterable text domain mapping (e.g., `"mywebsite.bft" -> "192.168.1.50"`) inside the state machine map.