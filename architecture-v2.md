# Building ProjectX: A Modular Blockchain in Go

*Architecture, design, requirements and a phase-by-phase build guide for Anthony GG's "Create a modular blockchain from scratch" series*

---

## 0. Read this first: what I could and could not verify

I could confirm that the playlist is Anthony GG's *Create a modular blockchain from scratch* (29 videos) and that the code lives in the open-source repo `anthdm/projectx` (MIT, Go 1.18+, built with `make build` / `make test`). The repo is split into the packages `api`, `core`, `crypto`, `network`, `types`, `util`. Individual episode titles I could confirm include "EP5: Creating the blockchain data structure", "EP6: BlockValidator", and a later episode on the virtual machine and contract state.

I could **not** retrieve the full list of 29 titles, and GitHub blocked me from reading the source files. So this guide is organised by **build phase**, in the order the series naturally builds things (which follows from the package layout and how a node like this has to be assembled). The phase details come from how this kind of node is standardly built and my knowledge of the series. Treat the phase-to-episode mapping as approximate: open the playlist, match each video to a phase, and trust the video over me wherever they differ. If you paste me the episode titles, I will redo this strictly video by video.

---

## 1. How blockchains work in general

### 1.1 The one-sentence version

A blockchain is a **replicated state machine driven by a tamper-evident, append-only log**, where many machines that do not trust each other agree on the log's contents without a central authority.

Break that down:

- **Log**: an ordered list of *transactions* (requests to change state: "move 5 coins from A to B", "call contract X").
- **Blocks**: transactions are batched into blocks. Batching makes agreement cheaper (agree on a batch, not on every item).
- **Chain**: each block contains the **hash of the previous block's header**. Change any old block and its hash changes, which breaks the link in every later block. History becomes tamper-evident.
- **State**: the result of applying all transactions in order (account balances, contract storage). Every honest node applies the same transactions in the same order and gets the same state. That is the "state machine" part.
- **Signatures**: a transaction is signed with the sender's private key. Anyone can verify with the public key. This replaces usernames and passwords: authorisation is cryptographic.
- **Consensus**: the rule that decides *who is allowed to produce the next block* and *which chain wins* if two exist. Proof of Work (Bitcoin), Proof of Stake (Ethereum), or a fixed validator set (Proof of Authority).
- **Peer-to-peer network**: nodes gossip transactions and blocks to each other. No central server.

### 1.2 The five problems every blockchain must solve

| Problem | Solution | Where it lives in ProjectX |
| --- | --- | --- |
| Who is allowed to do what? | Public-key signatures | `crypto` package, `Transaction.Sign/Verify` |
| How do we know history was not altered? | Hash chain (`PrevBlockHash`) | `core.Header`, `core.Validator` |
| How do we agree on the next block? | Consensus rule | Validator node / block-time ticker in `network.Server` |
| How do nodes find and talk to each other? | P2P transport and message protocol | `network` package |
| What does a transaction actually *do*? | State transition function / VM | `core` state + the VM |

### 1.3 What blockchains are used for

- **Digital money** (Bitcoin): a ledger with no bank.
- **Programmable money and apps** (Ethereum and similar): a VM executes contract code on every node.
- **Tokens, NFTs, DeFi**: exchange, lending and asset issuance with no operator.
- **Provenance and audit trails**: supply chain tracking, certificates, records that must not be quietly edited.
- **Consortium ledgers**: companies sharing a record without trusting one party to host it.
- **Learning**: building one is the best way to understand distributed systems, applied cryptography and state machines at the same time.

Honest caveat: if one trusted party can run the database, a normal database is usually better. Blockchains pay off when you genuinely need many mutually distrusting writers.

---

## 2. What ProjectX is trying to be

ProjectX is a **node framework**, not a finished coin. The word *modular* is the key design idea: every major concern is an interface, so you can swap implementations without touching the rest.

| Module | Interface idea | Implementations in the series |
| --- | --- | --- |
| Transport | how nodes exchange bytes | in-memory `LocalTransport` (for tests), then TCP |
| Encoding | how structs become bytes | Go `gob` and/or custom binary / JSON encoders and decoders |
| Validation | what makes a block valid | a `Validator` interface with a default implementation |
| Storage | where blocks and state live | in-memory store behind an interface |
| Execution | how transactions run | a small stack-based VM |

Why this matters for you as an engineer: the series is as much a lesson in **dependency inversion** as in blockchain. You can test a multi-node network in one process because the transport is an interface and the first implementation is just channels.

The consensus model in the series is simple (a validator node produces blocks on a timer). It is closer to **Proof of Authority** than to Bitcoin-style mining. Do not expect Proof of Work, forks or a fork-choice rule unless an episode adds them. The repo's own TODO file lists things like protobuf encoding, tests that stop using random data, choosing which pool transactions go into a new block, and block rewards, which tells you the project is a work in progress.

---

## 3. Requirements

### 3.1 Functional requirements

1. Define core types: `Hash` (32 bytes) and `Address` (20 bytes).
2. Generate keypairs, sign data and verify signatures.
3. Define `Header`, `Block` and `Transaction` with deterministic hashing and encode/decode.
4. Maintain a chain: genesis block, append blocks, look up by height or hash.
5. Validate blocks: correct height, correct previous hash, valid signatures, valid transactions.
6. Keep a pool of pending transactions (mempool) with de-duplication and ordering.
7. Let a validator node create a block from the pool on an interval and sign it.
8. Connect nodes over a transport, send and receive typed messages, broadcast.
9. Sync a node that is behind (ask peers for missing blocks).
10. Execute transactions with a VM and persist contract state.
11. Expose some of this through an API.

### 3.2 Non-functional requirements

- **Determinism**: the same inputs must produce the same hash and state on every machine. No maps iterated in random order, no `time.Now()` inside execution, no floats.
- **Concurrency safety**: the server runs several goroutines (network, ticker, API), so shared structures need locks or channel ownership.
- **Testability**: every package has tests; the network is testable in-process.
- **Extensibility**: new transport, encoding or VM without rewriting the core.

### 3.3 Tooling

Go 1.18+, `make`, and a standard library-first approach: `crypto/ecdsa`, `crypto/elliptic`, `crypto/sha256`, `encoding/gob`, `net`, `sync`. A logging library and `testify` are typical.

---

## 4. Architecture

### 4.1 The big picture

```
                         +---------------------------+
                         |        API (api/)         |
                         |  submit tx, query blocks  |
                         +-------------+-------------+
                                       |
+--------------------------------------v--------------------------------------+
|                               Server (network/)                             |
|                                                                             |
|   rpcCh <---- Transport ---->  peers      blockTime ticker (validator only)  |
|     |                                              |                        |
|     v                                              v                        |
|  RPC decode --> message handlers            createNewBlock()                |
|     |              |                              |                         |
|     |              v                              v                         |
|     |         TxPool (mempool) -----------> Block assembled + signed        |
|     |                                              |                        |
|     +--------------------------+-------------------+                        |
+--------------------------------|--------------------------------------------+
                                 v
+-----------------------------------------------------------------------------+
|                               Core (core/)                                  |
|   Blockchain  --  Validator  --  Storage  --  VM + State                    |
|   (headers, blocks, height)  (rules)  (blocks)   (execute txs)              |
+-----------------------------------------------------------------------------+
|        Types (types/)  Hash, Address         Crypto (crypto/)  keys, sigs    |
+-----------------------------------------------------------------------------+
```

### 4.2 Package responsibilities and dependency direction

Dependencies flow **downwards only**: `network` depends on `core`; `core` depends on `crypto` and `types`; `types` and `crypto` depend on nothing of yours. If `core` ever imports `network`, you have a cycle and a design bug. (The repo's TODO even mentions fixing potential circular dependencies in tests, which is exactly the trap.)

| Package | Owns |
| --- | --- |
| `types` | `Hash`, `Address`: plain value types |
| `crypto` | `PrivateKey`, `PublicKey`, `Signature`, address derivation |
| `core` | `Header`, `Block`, `Transaction`, `Blockchain`, `Validator`, `Storage`, VM, state, encoding |
| `network` | `Transport`, `LocalTransport`, TCP transport, `Server`, `TxPool`, messages, RPC handling |
| `api` | HTTP/JSON surface |
| `util` | test helpers (random hashes, random blocks) |

### 4.3 Data model

```go
type Hash [32]byte      // sha256 output
type Address [20]byte   // last 20 bytes of sha256(pubkey), Ethereum-style

type Header struct {
    Version       uint32
    DataHash      types.Hash   // hash over the block's transactions
    PrevBlockHash types.Hash   // THE link that makes it a chain
    Timestamp     int64
    Height        uint32
}

type Block struct {
    *Header
    Transactions []Transaction
    Validator    crypto.PublicKey // who produced it
    Signature    *crypto.Signature
    hash         types.Hash       // cached, not serialised
}

type Transaction struct {
    Data      []byte            // VM bytecode or payload
    From      crypto.PublicKey
    Signature *crypto.Signature
    // later: Nonce, value, etc.
}
```

Key modelling points:

- The **block hash is the hash of the header only**, not the whole block. The header commits to the transactions through `DataHash`, so a header is a compact, verifiable summary. Light clients rely on this.
- A block hash is **cached** and is not part of the serialised form, because it is derived.
- `Height` is the position in the chain; genesis is height 0.

---

## 5. Phase-by-phase build guide

For each phase: what you build, why, the key code, and how to know you are done. Build in this order and keep tests green at each step.

### Phase 1: Project skeleton and primitive types

**Goal:** a compiling repo with the foundation types.

- `go mod init`, a `Makefile` with `build` (output into `bin/`), `run` and `test`.
- `types.Hash` as `[32]byte` and `types.Address` as `[20]byte`.
- Helpers: `IsZero()`, `String()` (hex), `HashFromBytes([]byte)` that checks length and panics or errors.

**Why fixed-size arrays and not slices?** Arrays are comparable with `==` and usable as map keys, which you need for the tx pool and block lookups. Slices are not.

**Done when:** you can create, compare and print hashes in a test.

### Phase 2: Cryptography

**Goal:** identity and signing.

```go
type PrivateKey struct{ key *ecdsa.PrivateKey }
func GeneratePrivateKey() PrivateKey      // ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
func (k PrivateKey) PublicKey() PublicKey
func (k PrivateKey) Sign(data []byte) (*Signature, error)   // ecdsa.Sign over data

type PublicKey []byte                      // elliptic.MarshalCompressed
func (k PublicKey) Address() types.Address // sha256(pubkey)[12:]

type Signature struct{ R, S *big.Int }
func (s Signature) Verify(pub PublicKey, data []byte) bool
```

**Concepts to be sure you understand:**

- A private key signs; the public key verifies. The signature proves the holder of the private key approved *exactly these bytes*.
- An **address** is derived from the public key by hashing and truncating. It is the public identity of an account.
- You sign the **hash of the data**, not arbitrary-length data directly.

**Tests:** sign, verify true; verify with a different key, false; verify with modified data, false.

### Phase 3: Header and Block, with hashing and encoding

**Goal:** a block that can be hashed and serialised identically everywhere.

- `Header` and `Block` as above.
- Define **Encoder and Decoder interfaces** (`Encode(io.Writer) error`, `Decode(io.Reader) error`) with a generic wrapper, so serialisation format is swappable. The series starts with a hand-rolled binary encoding and moves to Go's `gob`; the TODO mentions protobuf as a future option.
- `Block.Hash(hasher)`: serialise the **header**, then sha256 it. Cache the result.
- `Block.Sign(privKey)` and `Block.Verify()`: the validator signs the header hash.
- Helper `NewBlockFromPrevHeader(prev *Header, txs []Transaction)` that computes height = prev+1, previous hash, data hash.

**Gotcha: determinism.** Hashing must use the exact same byte layout on every node. If you use `gob`, be aware its output is stable for the same types but is not meant as a cross-language wire format. That is fine for a learning project and is why real chains use RLP or protobuf.

**Tests:** encode then decode gives an equal block; same block hashes the same twice; mutate a field and the hash changes; signature verifies, and fails after tampering.

### Phase 4: Transactions

**Goal:** signed requests to change state.

- `Transaction{Data, From, Signature}`.
- `Sign(privKey)` signs the data (later: the tx hash), stores public key and signature.
- `Verify()` returns an error if there is no signature or if verification fails.
- `Hash()` is cached and computed by the hasher.
- Encode/decode like the block.
- A block's `DataHash` is computed from its transactions (the series uses a simple hash over them; real chains use a **Merkle tree** so you can prove a single tx is in a block without sending all of them).
- `Block.Verify()` also verifies every transaction.

**Replay attack to know about:** with no nonce, anyone can resubmit an old signed tx. Real chains add a per-account nonce. Expect this limitation in an early version and think about how you would add it.

### Phase 5: The Blockchain, storage and block validator

**Goal:** the chain itself.

```go
type Blockchain struct {
    lock      sync.RWMutex
    headers   []*Header          // index == height
    store     Storage            // interface: Put(*Block) error, Get(...)
    validator Validator          // interface: ValidateBlock(*Block) error
    // later: contract state, tx lookup
}

func NewBlockchain(genesis *Block) (*Blockchain, error)
func (bc *Blockchain) AddBlock(b *Block) error   // validate, then append
func (bc *Blockchain) GetHeader(height uint32) (*Header, error)
func (bc *Blockchain) Height() uint32            // len(headers)-1
func (bc *Blockchain) HasBlock(height uint32) bool
```

**The genesis block** is the hard-coded first block. Every node must create the *identical* genesis block, because every later `PrevBlockHash` chain traces back to it. Different genesis means a different network.

**The default validator** (this is the "BlockValidator" episode) checks, in order:

1. The block is not already in the chain.
2. `block.Height == chain.Height() + 1` (no gaps, no duplicates).
3. `block.PrevBlockHash == hash(chain's current header)`. This is the integrity check.
4. `block.Verify()`: the validator signature and every transaction signature are valid.

Only after validation does `AddBlock` append the header and store the block.

**Design point:** the validator is an interface and holds a back-reference to the chain (it needs the current height and last header). That mutual reference is why the series wires it up with a setter after construction.

**Tests:** add a valid block, success; add height+2, error; wrong previous hash, error; unsigned or tampered block, error; adding 1000 blocks keeps height correct.

### Phase 6: Transaction pool (mempool)

**Goal:** hold valid-but-unconfirmed transactions.

- A `TxPool` keyed by `tx.Hash()` so duplicates are rejected.
- `Add(tx)`, `Has(hash)`, `Flush()` (after they land in a block), `Len()`.
- Preserve **insertion order** (the series uses a sorted structure keyed by first-seen time) so block creation is deterministic and fair.
- Guard with a mutex.

**The TODO notes a real open question:** which pool transactions should go into the next block? Taking everything is the simple first answer; real chains pick by fee and nonce and cap by block size or gas.

### Phase 7: The transport abstraction and the Server

This is the phase that confuses people, so here is the mental model.

**Transport interface**: "something that can send bytes to a peer and hand me incoming messages."

```go
type NetAddr string

type RPC struct {
    From    NetAddr
    Payload io.Reader
}

type Transport interface {
    Consume() <-chan RPC          // incoming messages arrive on this channel
    Connect(Transport) error      // register a peer
    SendMessage(NetAddr, []byte) error
    Broadcast([]byte) error
    Addr() NetAddr
}
```

`LocalTransport` implements this with Go channels and a map of connected peers, all in one process. That is why you can spin up 3 "nodes" in a unit test with no sockets. Later a TCP implementation satisfies the same interface and the Server does not change.

**Server** is the node's main loop:

```go
func (s *Server) Start() {
    s.initTransports()                 // goroutine per transport pushing into s.rpcCh
    ticker := time.NewTicker(s.BlockTime)
free:
    for {
        select {
        case rpc := <-s.rpcCh:
            msg, _ := s.RPCDecodeFunc(rpc)       // bytes -> typed message
            s.RPCProcessor.ProcessMessage(msg)   // type switch
        case <-ticker.C:
            if s.isValidator { s.createNewBlock() }
        case <-s.quitCh:
            break free
        }
    }
}
```

**Messages and handlers:**

- RPC payload = `[1 byte message type][encoded body]`. Types such as `Transaction`, `Block`, `GetBlocks`, `Blocks`, `Status`, `GetStatus`.
- `RPCDecodeFunc` turns raw bytes into a `DecodedMessage{From, Data}` (the typed struct).
- `ProcessMessage` switches on the type:
  - **Transaction**: verify, reject if already in the pool, add, then **broadcast to peers** so it gossips.
  - **Block**: add to chain via the validator rules, then rebroadcast.
  - **Status / GetBlocks**: used for sync (Phase 8).

**Validator vs. regular node:** a node started with a private key is a block producer. On each tick it takes pool transactions, builds a block on top of the current header, signs it, adds it to its own chain, clears included transactions from the pool, and broadcasts the block. Nodes without a key only validate and relay.

**Why this design:** one goroutine owns the main loop and consumes from channels, so most state mutation is serialised and race conditions are rare. This is idiomatic Go: *share memory by communicating*.

**Tests:** two `LocalTransport`s connect and exchange a message; a tx sent to node A shows up in node B's pool; a block produced by the validator is accepted by a follower.

### Phase 8: Real networking and chain sync

**Goal:** nodes on separate processes that catch up.

- A **TCP transport**: listen, accept, spawn a read loop per peer, and a peer object that wraps the connection and can write to it. Incoming bytes become `RPC`s onto the same channel the Server already reads.
- **Handshake**: on connect, nodes exchange a `Status` message (version, current height).
- **Sync protocol**: if a peer reports a greater height, send `GetBlocks{From, To}`; the peer replies with `Blocks`; you validate and append them in order.
- A new node starts at genesis and syncs to the tip this way. This is the real meaning of "joining the network".

**Subtle problem:** what if blocks arrive out of order or while you are producing your own? A naive version assumes a single validator and sequential sync. A production chain needs fork handling and a fork-choice rule (longest chain, heaviest chain, finality). Know that this is where the series simplifies.

### Phase 9: The virtual machine

**Goal:** make transactions *do* something.

A small **stack-based VM**, like a tiny EVM or the JVM:

```go
type Instruction byte
const (
    InstrPushInt Instruction = iota
    InstrAdd
    InstrPushByte
    InstrPack
    InstrSub
    InstrStore
    // ...
)

type VM struct {
    data  []byte   // bytecode
    ip    int      // instruction pointer
    stack *Stack   // operands
    sp    int
}

func (vm *VM) Run() error {
    for {
        instr := Instruction(vm.data[vm.ip])
        if err := vm.Exec(instr); err != nil { return err }
        vm.ip++
        if vm.ip > len(vm.data)-1 { break }
    }
    return nil
}
```

How a stack machine works: instructions push operands and operators consume them. `PUSH 3; PUSH 2; ADD` leaves `5` on the stack. A transaction's `Data` is bytecode. When a block is added, the chain runs each transaction through a VM.

Build it incrementally: stack type, push/add/sub, then bytes and packing (for strings), then storage ops. Each opcode gets a test that asserts the stack contents.

**Why a VM at all?** It makes behaviour *data*, not hard-coded logic. Different users can deploy different logic, and every node executes it identically. Determinism is critical: the VM must have no access to time, randomness, the network or the file system.

**Real chains also add gas** (a cost per instruction) so an infinite loop cannot halt the network. A simple version may not have it yet. Notice that gap.

### Phase 10: Contract state

**Goal:** persistent storage that VM code can read and write.

- A `State` abstraction: a key-value store (`Put(key, value)`, `Get(key)`, `Delete(key)`), initially an in-memory map.
- Give the VM a reference to state and add opcodes such as **Store** and **Get** so bytecode can persist values, for example `key="FOO"`, `value=int`.
- Serialise values (ints, strings) with a small tagged encoding, since the state is raw bytes.
- The blockchain owns the state; when a block is added, each tx runs against it.

This is the leap from "ledger of transfers" to "programmable chain". Ethereum's "world state" and storage tries are the production-grade version of this key-value map.

### Phase 11: API and surrounding polish

- An `api` package serving HTTP/JSON: submit a transaction, get the latest block, get a block by height or hash, get a tx.
- It talks to the Server and Blockchain through their public methods only.
- Possible extras that appear in the TODO or are natural next steps: protobuf encoding, deduplicated test helpers (the `util` package), block rewards, logging cleanup.

---

## 6. End-to-end lifecycle of one transaction

If you can narrate this flow without looking, you understand the system.

1. **A user creates data and signs it** with their private key (crypto package).
2. The tx is submitted to **Node A** (via API or a message).
3. A's Server decodes the message, calls `tx.Verify()` and checks the pool does not already hold its hash.
4. A adds it to its **TxPool** and **broadcasts** it to peers via the Transport.
5. Peers repeat steps 3 to 4, so within moments every node has it. (Deduplication is what stops infinite gossip loops.)
6. The **validator's ticker** fires. It takes pending txs, builds a block on `currentHeader`, computes `DataHash`, signs the header.
7. The validator adds the block to its own chain (the Validator checks it) and **executes each tx** in the VM, updating state.
8. It **broadcasts the block**. Followers run the same validation: height, previous hash, signatures. They execute the txs themselves and reach identical state.
9. Everyone removes the included txs from their pool.
10. Later, a node that was offline connects, sees a higher height in `Status`, requests missing blocks, and replays them to catch up.

Notice that nobody trusts anybody: each node re-verifies everything.

---

## 7. Design decisions worth understanding (and what the series simplifies)

| Topic | In the series (simple) | Production blockchains |
| --- | --- | --- |
| Consensus | single designated validator, timer | PoW, PoS with voting, BFT with finality |
| Forks | not handled | fork choice, reorgs |
| Tx integrity | signature over data | nonce, chain id, fees, replay protection |
| DataHash | hash over txs | Merkle trees / tries |
| Encoding | gob or custom, protobuf planned | RLP, protobuf, SSZ |
| State | in-memory key-value | persistent Merkle-Patricia trie or similar |
| Execution limits | none or minimal | gas metering |
| Storage | in memory | LevelDB, RocksDB, etc. |
| Peer discovery | manual connect | DHT, bootnodes, gossip protocols |

This is not a criticism. Leaving these out is what makes the project buildable in 29 videos. Use the table as your list of "what I would add next".

---

## 8. How to replicate it on your own

1. **Watch one video at a time, then close it and rebuild from this guide's description.** Only peek when stuck. That is how it sticks.
2. **Write the test first for each phase.** The tests in this project are the specification.
3. **Keep the dependency direction clean.** If you need an import that points upward, redesign the interface.
4. **Run with the race detector** (`go test -race ./...`) once the Server exists.
5. **Draw the lifecycle in section 6 on paper** after Phase 7 and again after Phase 9.
6. **Stretch goals once it works:** add a Merkle root for `DataHash`; add a nonce to prevent replay; add gas to the VM; persist blocks to disk; add a second validator with round-robin turns; implement a fork-choice rule.

### Self-check questions

- Why does the block hash cover only the header?
- What exactly breaks if two nodes build different genesis blocks?
- Why must the VM be deterministic, and what would you remove from the Go standard library to guarantee that?
- Why is the `Transport` an interface, and what does it buy you in tests?
- What attack does a missing nonce allow?
- What happens in this design if two validators produce a block at the same height?

---

## 9. Next step

If you paste the 29 episode titles (or any you want expanded), I can rewrite this as a strict video-by-video walkthrough with the exact code structure for each episode, plus a test checklist per video.

---

## 10. Video-by-video walkthrough (using your real episode list)

**How to read this section.** It supersedes the phase ordering in section 5 wherever the two differ. The real series builds in this order: transport, types and crypto, chain, validator, mempool, RPC, block creation and broadcasting, VM, contract state, syncing and TCP, JSON API, then application layers (NFTs, a native currency, accounts, rewards).

**Honesty notes.**

- I have not watched these videos. Each entry below combines the title with how this kind of component is standardly built and my recollection of the series. Where I am inferring from a title alone, I say so. Check each against the video.
- Your list has 27 titles, while the playlist reports 29 videos. EP14 is missing from your list (it jumps from EP13 to EP15), and the later live episodes are unnumbered, so a couple may be absent. Tell me what is missing and I will slot it in.
- Section 0 said consensus was a simple timer-driven validator and that rewards were unconfirmed. The final titles ("Accounts And The Coinbase", "Block Validator Rewards") show the series does add a native currency and rewards by the end.

**Format per video:** what you build, the concepts, a code sketch, how it connects to what exists, and how you know you are done.

---

### Part A: Foundations (EP1 to EP6)

#### Video 1. EP1: Transport layer

**Builds:** the `network` package skeleton: a `Transport` interface, an in-memory `LocalTransport`, and a first `Server` shell.

**Concepts:** "program to an interface" so the network can be swapped later; Go channels as message queues; `sync.RWMutex` guarding a peer map.

```go
type NetAddr string
type RPC struct { From NetAddr; Payload io.Reader }

type Transport interface {
    Consume() <-chan RPC
    Connect(Transport) error
    SendMessage(NetAddr, []byte) error
    Addr() NetAddr
}

type LocalTransport struct {
    addr   NetAddr
    consumeCh chan RPC
    lock   sync.RWMutex
    peers  map[NetAddr]*LocalTransport
}
```

`Connect` registers the other transport in `peers`. `SendMessage` looks up the peer and pushes an `RPC` into that peer's `consumeCh`. The `Server` takes `ServerOpts{Transports []Transport}`, starts a goroutine per transport that forwards into one `rpcCh`, and runs a `select` loop (messages or quit).

**Connects to:** everything later. TCP in video 19 is just a second implementation of this interface.

**Done when:** two local transports connect and one receives the other's bytes in a test.

---

#### Video 2. EP2: Block and Transaction basics

**Builds:** `types.Hash` (`[32]byte`), `types.Address` (`[20]byte`), `core.Header`, `core.Block`, `core.Transaction`, and encoding.

**Concepts:** a block's identity is the hash of its **header**; the header commits to the contents via `DataHash`; fixed-size arrays are comparable and usable as map keys.

```go
type Header struct {
    Version       uint32
    DataHash      types.Hash
    PrevBlockHash types.Hash
    Timestamp     int64
    Height        uint32
}
```

Expect a first hand-rolled binary `EncodeBinary` / `DecodeBinary` using `encoding/binary` (`binary.Write` / `binary.Read` on the fields). The block hash is computed through a `Hasher` interface so the hash algorithm is swappable, and the result is cached on the block.

**Done when:** encode then decode a header or block yields an equal struct, and the hash is stable across calls.

---

#### Video 3. EP3: Crypto keypairs and signatures

**Builds:** the `crypto` package.

**Concepts:** elliptic-curve keypairs, signing a message, verifying a signature, deriving an address from a public key.

```go
func GeneratePrivateKey() PrivateKey            // ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
func (k PrivateKey) PublicKey() PublicKey
func (k PrivateKey) Sign(data []byte) (*Signature, error)
func (k PublicKey) Address() types.Address      // hash(pubkey), last 20 bytes
func (s Signature) Verify(pub PublicKey, data []byte) bool
```

A private key signs, a public key verifies; the address is the public identity. Test three cases: valid, wrong key, tampered data.

**Connects to:** videos 4, 7, 21, 26.

---

#### Video 4. EP4: Block and TX signing and verification

**Builds:** `Sign` and `Verify` on both `Block` and `Transaction`.

**Concepts:** who signs what. A **transaction** is signed by its sender. A **block** is signed by the validator that produced it, over the header hash. A block is only valid if its own signature and every contained transaction signature verify.

```go
func (tx *Transaction) Sign(k crypto.PrivateKey) error   // stores From + Signature
func (tx *Transaction) Verify() error                    // errors on missing or bad signature
func (b *Block) Sign(k crypto.PrivateKey) error
func (b *Block) Verify() error                           // block sig + every tx.Verify()
```

**Done when:** tampering with block data or any tx makes `Verify` fail.

---

#### Video 5. EP5: Creating the blockchain data structure

**Builds:** `core.Blockchain`, storage, and the genesis block.

**Concepts:** the chain is an ordered slice of headers (index equals height) plus a `Storage` interface that holds full blocks. A chain must be created *with* a genesis block, so it is never empty.

```go
type Blockchain struct {
    lock      sync.RWMutex
    headers   []*Header
    store     Storage
    validator Validator
}
func NewBlockchain(genesis *Block) (*Blockchain, error)
func (bc *Blockchain) AddBlock(b *Block) error
func (bc *Blockchain) GetHeader(h uint32) (*Header, error)
func (bc *Blockchain) Height() uint32   // len(headers) - 1
```

The `Validator` interface is injected after construction (`SetValidator`) because the validator needs a reference back to the chain.

**Done when:** you can add 1000 blocks in a loop and `Height()` is correct.

---

#### Video 6. EP6: BlockValidator

**Builds:** the default `BlockValidator`.

Ordered checks in `ValidateBlock`: (1) the block is not already in the chain, (2) `block.Height == chain.Height()+1`, (3) `block.PrevBlockHash` equals the hash of the current tip header, (4) `block.Verify()`. Only then does `AddBlock` append.

**Why it matters:** check 3 is the entire integrity guarantee of a blockchain in one comparison.

**Done when:** wrong height, wrong previous hash and tampered signature each give a distinct error.

---

### Part B: Node behaviour (EP7 to EP13)

#### Video 7. EP7: TX mempool part 1

**Builds:** `TxPool`.

**Concepts:** the mempool holds validated, not-yet-included transactions. It is keyed by tx hash for O(1) duplicate detection and has to be concurrency safe.

```go
type TxPool struct {
    lock         sync.RWMutex
    transactions map[types.Hash]*Transaction
}
func (p *TxPool) Add(tx *Transaction) // no-op if already present
func (p *TxPool) Has(h types.Hash) bool
func (p *TxPool) Len() int
func (p *TxPool) Flush()
```

The tx hash is cached after first compute (so it is not rehashed per lookup).

---

#### Video 8. EP8: TX mempool part 2

**Builds (from title and the repo's own TODO):** ordering and housekeeping. A Go map has random iteration order, which is poison for a deterministic chain, so the pool needs a stable ordering, typically by the time each tx was first seen, via a sortable wrapper. It likely also separates "all known" from "pending" transactions and bounds the pool size.

**Open question the repo itself flags:** which pool txs go into the next block. Start by taking all of them; later versions would apply fee, nonce and size limits.

**Done when:** adding txs in order A, B, C always returns them A, B, C.

---

#### Video 9. EP9: RPC protocol

**Builds:** the message layer on top of `Transport`.

**Concepts:** the transport only moves bytes. A protocol decides what the bytes mean. Typical layout: `[1 byte MessageType][encoded body]`.

```go
type MessageType byte
const ( MessageTypeTx MessageType = 0x1; MessageTypeBlock /* ... */ )

type Message struct { Header MessageType; Data []byte }
type DecodedMessage struct { From NetAddr; Data any }

type RPCDecodeFunc func(RPC) (*DecodedMessage, error)
type RPCProcessor interface { ProcessMessage(*DecodedMessage) error }
```

`DefaultRPCDecodeFunc` reads the message, switches on the type, and decodes the body into a `*Transaction`, `*Block`, etc. The `Server` implements `RPCProcessor` and switches on the decoded type.

**Why design it this way:** the decode function and processor are injectable, so tests and alternative protocols plug in.

---

#### Video 10. EP10: RPC protocol part 2

**Builds:** the first real handler: **receiving and relaying transactions**.

`processTransaction(tx)`: verify, drop if the pool already has the hash, set `FirstSeen`, add to the pool, then **broadcast to peers**. Deduplication is what stops infinite gossip loops. This also adds `Broadcast` (send to all connected peers) to the transport.

**Done when:** a tx sent to node A shows up in nodes B and C pools, exactly once each.

---

#### Video 11. EP11: Creating our first blocks

**Builds:** block production.

The `Server` gets `PrivateKey` and `BlockTime` options. A node with a key is a **validator**; others only validate and relay. A `time.Ticker` in the main `select` loop fires `createNewBlock()`:

1. Read the current tip header from the chain.
2. Pull pending txs from the pool.
3. Build a block on top (`NewBlockFromPrevHeader`: height+1, previous hash, `DataHash` over the txs).
4. Sign with the validator key.
5. `chain.AddBlock` (validated like any block).
6. Clear the included txs from the pool.

This is the consensus mechanism of the series: **one designated producer, a timer**.

---

#### Video 12. EP12: Creating blocks part 2

**Builds (from title):** finishing and hardening block creation: computing `DataHash` correctly, ensuring the validator's own block passes its own validation, flushing the right txs, and fixing the bugs that appear once blocks are produced repeatedly in a running loop. Expect lots of test fixes around hashing and height.

**Done when:** a validator node runs for N seconds and the chain height rises by about N / BlockTime with every block valid.

---

#### Video 13. EP13: Broadcasting blocks

**Builds:** block gossip.

After a validator creates a block it **encodes it and broadcasts** a `MessageTypeBlock`. Followers decode it, run the full `BlockValidator`, add it to their chain, and relay it. Make sure a node does not re-broadcast a block it already has, or the network ping-pongs forever.

**Note:** your list skips EP14. Whatever it covers (likely cleanup or a bridge to the VM), I have no verified content for it.

---

### Part C: The virtual machine (EP15 to "Custom Smart Contracts")

#### Video 14. EP15: Implementing the virtual machine

**Builds:** the `VM` type and its run loop, with a stack. This is the conceptual jump from "ledger" to "programmable chain": a tx's `Data` field becomes **bytecode** that every node executes identically.

```go
type VM struct {
    data  []byte
    ip    int
    stack *Stack
}
func (vm *VM) Run() error {
    for vm.ip < len(vm.data) {
        instr := Instruction(vm.data[vm.ip])
        if err := vm.Exec(instr); err != nil { return err }
        vm.ip++
    }
    return nil
}
```

**Concepts:** instruction pointer, fetch-decode-execute, stack discipline. **Determinism:** the VM must not touch time, randomness or the network.

---

#### Video 15. EP16: Virtual machine basics

**Builds:** the first useful instruction set: push int, push byte, add, sub, and packing bytes into a string or slice. Each instruction pops operands, computes, pushes the result. Test by running small programs and asserting the stack, for example `push 3; push 2; add` leaves `5`.

**Gotcha:** an instruction like `Pack` consumes a *count* from the stack and then that many bytes, so push order matters. Write the test before the opcode.

---

#### Video 16. Virtual machine contract state

**Builds:** persistent state the VM can read and write.

```go
type State struct { data map[string][]byte }
func (s *State) Put(k, v []byte) error
func (s *State) Get(k []byte) ([]byte, error)
func (s *State) Delete(k []byte) error
```

The VM receives a `*State`; new instructions (store and get) let bytecode persist and retrieve values by key. The blockchain owns the state and runs each tx in a block against it.

**The key insight:** every node executes the same txs in the same order, so every node's state ends up identical. That is the "replicated state machine".

---

#### Video 17. Custom smart contracts

**Builds (from title):** writing real programs on the VM, bytecode in a transaction's `Data`, that read and write state, plus any helper or assembler needed to author them. This validates that the VM can express something useful. I do not have verified details of the specific contracts used, so follow the video here.

---

### Part D: Distribution (syncing and TCP)

#### Video 18. Syncing blocks

**Builds (from title):** the logic for a node that is behind to ask for and apply missing blocks. Typical messages: a status/height exchange, a `GetBlocks{From, To}` request, and a `Blocks` response. Blocks are validated and appended **in order**.

**Concepts:** this is what "joining the network" means: start at genesis, learn the tip height from a peer, fetch what you lack.

---

#### Video 19. TCP networking

**Builds:** a `TCPTransport` implementing the same `Transport` interface from video 1.

**Shape:** `net.Listen`; an accept loop; a `TCPPeer` wrapping each `net.Conn`; a read loop per peer that turns incoming bytes into `RPC` values on the shared channel; a handler for new peers. Because the `Server` consumes the interface, **no server logic changes**. This is the payoff of video 1.

---

#### Video 20. Syncing our nodes

**Builds (from title):** wiring video 18's sync logic onto video 19's TCP transport: bootstrap nodes to dial on start, status exchange on connect, then request missing blocks. At this point you can run separate processes on different ports and watch a late joiner catch up.

**Known limit:** with a single producer there are no forks. A multi-producer design would need a fork-choice rule.

---

#### Video 21. Private and public key cryptography

**Builds (from title only):** a return to the `crypto` package, likely to refine key handling (serialisation of keys and signatures, address derivation, key helpers) now that real nodes and later accounts depend on it. I cannot say exactly what changed. Watch for what is added, then check that sign/verify tests still pass.

---

### Part E: External API

#### Video 22. JSON RPC Server

**Builds:** the `api` package: an HTTP server exposing read endpoints (latest block, block by height or hash, tx by hash).

**Design rule:** the API only calls public methods on the `Blockchain` and `Server`. It must not reach into node internals, so the dependency arrow stays `api -> core`.

---

#### Video 23. JSON RPC sending transactions

**Builds:** a **write** endpoint. A client sends a transaction (encoded, signed on the client side); the API decodes it and hands it to the server, which verifies it, adds it to the pool and gossips it, exactly the path from video 10. Hand it off through a channel or a method call, not by touching the pool directly.

**Security idea:** the server never sees private keys; clients sign locally.

---

### Part F: Application layers on the chain

#### Video 24. Programming an NFT marketplace

**Builds (from title and my recollection):** native, non-VM transaction types for NFTs: roughly a **collection** transaction (create a collection with metadata) and a **mint** transaction (create an item inside one). This requires a transaction type field and a switch on it when applying a tx. It shows two models side by side: arbitrary bytecode on the VM versus built-in typed transactions. Verify details against the video.

**Concept:** a token is just an entry in chain state attributed to an address.

---

#### Video 25. Coding our own crypto currency

**Builds (from title):** native value transfer: a transaction that moves an amount from one address to another, and the checks that make it safe (sender has enough, amount valid). This is where the chain becomes a money ledger instead of a data log.

**Gotchas to think about:** double spending, integer overflow on balances, and replay attacks (a nonce per account is the standard fix, and I do not know whether the series adds one).

---

#### Video 26. Accounts and the coinbase

**Builds (from title):** an account model: per-address balances held in state, and a **coinbase** (the source address that mints new coins, so supply is not fixed at genesis).

```go
type Account struct { Address types.Address; Balance uint64 }
type AccountState struct { accounts map[types.Address]*Account }
// Transfer(from, to, amount) checks balance, debits, credits atomically
```

This is the Ethereum-style **account model**, in contrast to Bitcoin's UTXO model.

---

#### Video 27. Block validator rewards

**Builds (from title):** paying the block producer. When a validator creates a block it earns a reward credited via the coinbase. This also closes the repo TODO item about block rewards.

**Be careful about:** *where* the reward is applied (in block creation or when applying blocks) and making sure followers recompute it identically, or their state will diverge from the producer's.

---

### Dependency map across the videos

| Needs | Introduced in |
| --- | --- |
| Types (Hash, Address) | 2 |
| Crypto | 3 |
| Signing and verification | 4 |
| Chain and validator | 5, 6 |
| Mempool | 7, 8 |
| Message protocol | 9 |
| Tx gossip | 10 |
| Block production | 11, 12 |
| Block gossip | 13 |
| VM and state | 14 to 17 |
| Sync and TCP | 18 to 20 |
| API | 22, 23 |
| NFTs, currency, accounts, rewards | 24 to 27 |

### Study loop for each video

1. Read the entry above, then try to write the interface and the tests yourself for 10 minutes.
2. Watch the video and compare. Note where your design differs and why.
3. Close the video and rebuild from memory.
4. Run `go test -race ./...`.
5. Add one self-chosen extension per part (a Merkle root, a tx nonce, gas in the VM, disk storage).

### Questions that will tell you if you understand each part

- **Part A:** what, precisely, does the block hash cover, and why?
- **Part B:** why does gossip need deduplication, and where is it enforced?
- **Part C:** why must two nodes get identical state after executing the same block?
- **Part D:** what does the Server not know about TCP, and why is that useful?
- **Part F:** what could a malicious sender do if transfers had no nonce?

If any title above is mislabeled, or you can tell me what EP14 and the missing two videos are, I will update this section.
