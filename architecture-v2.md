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

---

## 11. Blockchain from zero: a learning path (read this BEFORE sections 4 to 10)

This part assumes you are a competent software engineer and know nothing about blockchains. It teaches the ideas in the order they depend on each other, using only Go's standard library, so that when you reach the ProjectX walkthrough (section 10) every piece is already something you understand and could have invented.

**How to use it.** Each module has: *the idea* (intuition first), *what you must be able to explain*, *a Go exercise*, and *how it shows up in a blockchain*. Do the exercises. Reading alone will not make this stick. Plan on roughly 10 to 12 weeks part-time, but skip modules you already know well.

**The learning path at a glance**

| # | Module | Gives you |
| --- | --- | --- |
| 0 | The problem and the history | why any of this exists |
| 1 | Hash functions | tamper evidence |
| 2 | Digital signatures | identity and authorisation |
| 3 | Hash-linked data: chains and Merkle trees | the "block" and "chain" |
| 4 | Serialisation and determinism | agreement on bytes |
| 5 | Ledgers and state machines | what the chain actually computes |
| 6 | Distributed systems basics | why agreement is hard |
| 7 | Consensus | who decides the next block |
| 8 | Networking | gossip and sync |
| 9 | Mempool, fees and incentives | why people behave |
| 10 | Execution and smart contracts | programmable chains |
| 11 | Storage | persistence and state proofs |
| 12 | Security thinking | what attackers do |
| 13 | Uses and non-uses | when to use one |
| 14 | Go skills checklist | the language tools you need |
| 15 | Capstone ladder | build your own, step by step |

---

### Module 0: The problem, and how the field evolved

#### 0.1 The problem blockchains solve

Imagine a shared notebook that records who owns what. Today a bank, a company or a government holds that notebook, and everyone trusts it. Three things can go wrong with a trusted keeper: it can **lie or be hacked** (edit history), it can **refuse service** (censor you), or it can **fail** (lose the notebook).

Now remove the keeper. Hundreds of strangers each hold a copy of the notebook. Immediately you hit hard questions:

1. **Who may write?** (Authorisation without accounts and passwords.)
2. **How do I know the history was not altered?** (Integrity.)
3. **When two people write conflicting entries at the same moment, which wins?** (Agreement, called *consensus*.)
4. **Why would anyone bother to run a copy honestly?** (Incentives.)

A blockchain is the combined answer: signatures for 1, hash-linking for 2, a consensus protocol for 3, and economic rewards for 4.

**The double-spend problem** is the classic hard case. Digital files copy for free. If I hold a token and send it to both Alice and Bob, who really received it? Physical cash cannot do this. With a trusted bank, the bank just refuses the second payment. Without a bank, the *network* must agree on a single ordering of payments, so the second one is rejected. Order is everything. This is why blockchains are fundamentally about **agreeing on an order of events**.

#### 0.2 A short history (so you know where each idea came from)

| Year | Event | Why it matters |
| --- | --- | --- |
| 1979 | Merkle trees (Ralph Merkle) | efficient proof that data is part of a set |
| 1982 | Byzantine Generals Problem (Lamport, Shostak, Pease) | formal statement of agreeing when some participants lie |
| 1983 to 1990s | David Chaum's digital cash (eCash, DigiCash) | anonymous digital money, but centrally issued |
| 1991 | Haber and Stornetta: timestamping documents with hash-linked records | the chain-of-hashes idea |
| 1994 | Nick Szabo's "smart contracts" concept | programmable agreements |
| 1997 | Adam Back's Hashcash | proof of work as anti-spam |
| 1998 to 2005 | b-money (Wei Dai), Bit Gold (Szabo), RPOW (Hal Finney) | near-misses at decentralised digital money |
| 1999 | PBFT (Castro and Liskov) | practical Byzantine fault tolerance |
| 2008 | Bitcoin whitepaper by "Satoshi Nakamoto" | combines the pieces into a working decentralised currency |
| 2009 | Bitcoin network launches (genesis block, January) | first working public blockchain |
| 2013 to 2015 | Ethereum proposed (Vitalik Buterin) and launched (2015) | general-purpose programmable blockchain |
| 2016 | "The DAO" exploit and the resulting Ethereum fork | smart-contract bugs are real money; "code is law" debate |
| 2017 | ICO boom; many other chains (e.g. Cosmos, Polkadot lines of work) | explosion of tokens and platform experiments |
| 2020 to 2021 | DeFi and NFTs go mainstream | lending, exchanges and collectibles as contracts |
| 2022 | Ethereum moves from proof of work to proof of stake ("the Merge") | major consensus change on a live network |
| 2020s | Rollups / layer-2s, and modular designs that separate execution, settlement, consensus and data availability | scaling by splitting responsibilities |

The key conceptual leap in 2008 was not a new primitive. Hashes, signatures, Merkle trees, proof of work and peer-to-peer networks all existed. Bitcoin's contribution was a **combination that made the order of transactions agreeable among strangers, with incentives that keep them honest.** Ethereum's leap was making the chain compute arbitrary programs, not just track balances.

You will notice the series you are following is called a *modular* blockchain: that word describes this last trend, where consensus, networking, execution and storage are separate swappable components.

**You must be able to explain:** the double-spend problem; why ordering is the core difficulty; what each of the four sub-problems (authorisation, integrity, agreement, incentives) is solved by.

---

### Module 1: Hash functions

#### The idea

A cryptographic hash function takes any bytes and returns a fixed-size "fingerprint" (SHA-256 gives 32 bytes). Properties you rely on:

- **Deterministic:** the same input always gives the same output.
- **Fast to compute.**
- **Avalanche effect:** change one bit of input and roughly half the output bits flip.
- **Preimage resistance:** given a hash, you cannot practically find an input that produces it.
- **Collision resistance:** you cannot practically find two different inputs with the same hash.

Think of a hash as a **commitment**: publishing `H(data)` locks you into `data` without revealing it, and anyone holding `data` can verify.

#### What it is used for in a blockchain

1. **Block identity:** a block is referred to by the hash of its header.
2. **Linking:** each block stores the previous block's hash.
3. **Summarising data:** a header holds a hash of all its transactions.
4. **Proof of work:** finding a hash below a target is the "work".
5. **Addresses:** derived from hashes of public keys.

#### Exercise 1.1: see the avalanche

```go
package main

import (
    "crypto/sha256"
    "fmt"
)

func main() {
    fmt.Printf("%x\n", sha256.Sum256([]byte("hello")))
    fmt.Printf("%x\n", sha256.Sum256([]byte("hellp")))
}
```

Run it, then write a function that counts how many bits differ between the two outputs (XOR the bytes and count set bits with `math/bits.OnesCount8`). Expect roughly 128 of 256.

#### Exercise 1.2: a commitment

Write `Commit(secret []byte, nonce []byte) [32]byte` and `Verify(...)`. Explain why you need the random nonce (hint: otherwise someone can brute-force small secrets such as "yes" or "no").

**You must be able to explain:** why you cannot "decrypt" a hash; why one-bit changes break everything downstream; what a collision attack would mean for a blockchain.

---

### Module 2: Digital signatures

#### The idea

You generate a **private key** (a big secret number) and derive a **public key** from it by a one-way mathematical operation. Properties:

- Only the private key can produce a valid signature over a message.
- Anyone with the public key can verify the signature.
- Changing even one bit of the message invalidates the signature.
- You cannot compute the private key from the public key.

This replaces accounts and passwords. **Your identity is your public key (or an address derived from it).** Authorisation is "can you produce a valid signature for this exact message?" No server needs to know you.

#### Elliptic curves, practically

You do not need the mathematics on day one. Know: modern signatures (ECDSA, Ed25519) use elliptic curves because they give strong security with small keys. Bitcoin and Ethereum use the secp256k1 curve; Go's standard library gives you P-256 (`crypto/ecdsa`, `crypto/elliptic`) and Ed25519 (`crypto/ed25519`). For learning, either is fine.

#### An address

An **address** is typically a hash of the public key, truncated. It is shorter and adds a layer of indirection. Chains differ in the details.

#### Exercise 2.1: sign and verify

```go
pub, priv, _ := ed25519.GenerateKey(rand.Reader)
msg := []byte("send 5 coins to Bob")
sig := ed25519.Sign(priv, msg)
fmt.Println(ed25519.Verify(pub, msg, sig))                  // true
fmt.Println(ed25519.Verify(pub, []byte("send 500"), sig))   // false
```

Then repeat with ECDSA on P-256 (`ecdsa.GenerateKey`, `ecdsa.SignASN1`, `ecdsa.VerifyASN1`) and derive an address with `sha256.Sum256(pubBytes)[12:]`.

#### The replay problem

A valid signature is valid forever. If you sign "pay Bob 5", an attacker can resubmit the same signed message again and again. Two standard fixes: include a **nonce** (a per-account counter) in the signed data, and include a **chain ID** so a signature on one network cannot be replayed on another. Make sure you can explain why signing alone is not enough.

**You must be able to explain:** why a private key leak is total and unrecoverable; why you sign a hash or canonical bytes, not a loose struct; why replay protection exists.

---

### Module 3: Hash-linked data structures

#### 3.1 The hash chain (the "chain" in blockchain)

Each record stores the hash of the previous record. To alter record 5, you must change its hash, which changes record 6's stored link, which changes its hash, and so on. History becomes **tamper-evident**: you can detect any change by recomputing.

Note carefully: a hash chain alone does **not** prevent tampering. Anyone can recompute every later hash after editing. What it gives you is *detection against anyone who holds a copy of the latest hash*. Preventing a rewrite from being accepted is consensus's job (modules 6 and 7).

```go
type Block struct {
    Index    uint64
    Data     []byte
    PrevHash [32]byte
    Hash     [32]byte
}

func (b *Block) ComputeHash() [32]byte {
    h := sha256.New()
    binary.Write(h, binary.BigEndian, b.Index)
    binary.Write(h, binary.BigEndian, uint64(len(b.Data))) // length prefix avoids ambiguity
    h.Write(b.Data)
    h.Write(b.PrevHash[:])
    var out [32]byte
    copy(out[:], h.Sum(nil))
    return out
}
```

**Exercise 3.1:** build a `Chain` type with `Append(data)` and `Validate() bool`. Create 10 blocks, then edit block 3's data and show `Validate` fails and exactly where. Then try to "fix" it by recomputing hashes from block 3 onward, and see it pass. This is the demonstration that makes the need for consensus concrete.

#### 3.2 Merkle trees

A block can hold thousands of transactions. A **Merkle tree** summarises them into one root hash: hash each transaction (the leaves), then hash pairs of hashes upward until one hash remains.

Why this beats hashing all the data together: you can prove that a transaction is in a block by supplying just the **sibling hashes along its path** (about log2(n) hashes). A phone app can verify a payment without downloading the whole chain. This is called a *Merkle proof*, and it underlies light clients.

```go
func merkleRoot(leaves [][32]byte) [32]byte {
    if len(leaves) == 0 {
        return [32]byte{}
    }
    level := leaves
    for len(level) > 1 {
        var next [][32]byte
        for i := 0; i < len(level); i += 2 {
            l := level[i]
            r := l // duplicate the last node if the count is odd
            if i+1 < len(level) {
                r = level[i+1]
            }
            next = append(next, sha256.Sum256(append(l[:], r[:]...)))
        }
        level = next
    }
    return level[0]
}
```

**Exercise 3.2:** implement `Proof(leaves, index) [][32]byte` and `VerifyProof(root, leaf, index, proof) bool`. Write tests that fail when you flip one bit of the leaf, the proof, or the root.

**A subtlety to be aware of:** naive duplication of odd nodes has a known second-preimage / duplicate-leaf weakness in Bitcoin's design. Real systems add domain-separation prefixes (leaf versus internal-node markers). Add a `0x00` byte before hashing leaves and `0x01` before hashing internal nodes in your own version and say why.

**You must be able to explain:** the difference between hash-chaining and hash-*tree*-ing; what a block header contains and why it can be so small; what a Merkle proof proves and does not prove.

---

### Module 4: Serialisation and determinism

#### The idea

Hashes and signatures operate on **bytes**. Two nodes that hold "the same" transaction must produce **byte-identical** encodings or their hashes (and signatures) will differ. Therefore your encoding must be *canonical*: exactly one valid byte sequence per value.

Things that quietly break this:

- **Map iteration order** in Go is randomised. Never serialise a `map` by ranging over it; sort the keys first.
- **Floating point** differs across hardware and is rounded. Use integers (for money, use the smallest unit).
- **Struct field order and padding.** Encode fields explicitly in a fixed order.
- **Endianness.** Always pick one (big-endian is common) and stay with it.
- **Variable-length data without a length prefix** is ambiguous: `("ab","c")` and `("a","bc")` concatenate to the same bytes.
- **Time:** `time.Now()` is different on every machine. A block carries its own timestamp as data.

Real chains use purpose-built formats (Ethereum's RLP, Protobuf, SSZ, Bincode). Go's `encoding/gob` is convenient but not designed as a cross-version wire format, which is acceptable for learning and a reason the ProjectX TODO mentions protobuf.

#### Exercise 4.1

Write `func (tx *Tx) Bytes() []byte` using `encoding/binary` and length prefixes. Prove it is canonical with a test that round-trips thousands of random transactions. Then deliberately break it (serialise a map by ranging) and find the flaky test.

**You must be able to explain:** why two honest nodes could disagree on a hash even though they see the same transaction.

---

### Module 5: Ledgers and state machines

#### The big reframing

Stop thinking "a chain of blocks". Think: **a blockchain is a log of transactions that drives a state machine.**

```
state_(n+1) = apply(state_n, transaction)
```

If every node starts with the same genesis state and applies the same transactions in the same order using the same deterministic `apply`, every node ends with the same state. That is the whole point of the chain: it is the agreed *order of inputs* to a deterministic machine. This idea is called **state machine replication**, and it predates blockchains.

#### Two ledger models

- **Account model** (Ethereum, and ProjectX's later videos): the state is a map `address -> {balance, nonce}`. A transfer subtracts from one entry and adds to another. Simple to reason about.
- **UTXO model** (Bitcoin): there are no balances. The state is a set of *unspent transaction outputs*, like banknotes. A transaction consumes some outputs and creates new ones. Naturally parallel and easy to verify independently, but less natural for programs.

#### Exercise 5.1: your first state machine

```go
type Tx struct {
    From, To string
    Amount   uint64
    Nonce    uint64
}

type State struct {
    Balances map[string]uint64
    Nonces   map[string]uint64
}

var (
    ErrBadNonce = errors.New("bad nonce")
    ErrFunds    = errors.New("insufficient funds")
)

func (s *State) Apply(tx Tx) error {
    if tx.Nonce != s.Nonces[tx.From] {
        return ErrBadNonce
    }
    if s.Balances[tx.From] < tx.Amount {
        return ErrFunds
    }
    if s.Balances[tx.To]+tx.Amount < s.Balances[tx.To] {
        return errors.New("overflow")
    }
    s.Balances[tx.From] -= tx.Amount
    s.Balances[tx.To] += tx.Amount
    s.Nonces[tx.From]++
    return nil
}
```

Extend it: apply a *block* of transactions atomically (if any tx is invalid, either reject the whole block or define exactly how invalid txs are skipped, and say which is better and why). Add a copy-on-write or undo log so you can roll back a failed block.

#### Exercise 5.2: demonstrate double spending

Give Alice 10 coins. Create two transactions from Alice (to Bob and to Carol) both for 10. Show that applying them in different orders yields different outcomes, then show that agreeing on *one order* makes one fail deterministically. **Now you have rediscovered why consensus exists.**

**You must be able to explain:** why a nonce makes the order of one account's transactions unambiguous; what "deterministic" has to mean for `Apply`; the pros and cons of account versus UTXO.

---

### Module 6: Distributed systems basics

You are a software engineer, so some of this will be familiar. Here it is through the blockchain lens.

- **Asynchrony:** messages can be delayed, reordered, duplicated or lost. There is no shared clock.
- **Failure models:** *crash faults* (a node stops) are the easier case. *Byzantine faults* (a node lies, colludes, or sends different answers to different peers) are the blockchain case, because any participant may be an attacker.
- **Replication:** keeping copies on many machines for availability. The hard part is keeping them consistent.
- **Safety vs liveness:** *safety* means "nothing bad ever happens" (two nodes never finalise conflicting blocks). *Liveness* means "something good eventually happens" (new blocks keep being produced). Protocols often trade one for the other under bad network conditions.
- **CAP and FLP, in one paragraph each.** CAP: during a network partition you must choose between consistency and availability. FLP: in a fully asynchronous network, no deterministic protocol can guarantee consensus if even one node may crash. Real protocols escape FLP with timeouts, randomness or synchrony assumptions. Do not memorise the proofs; understand why the results force every consensus protocol to make assumptions.
- **Quorums:** many protocols require agreement from more than half, or more than two-thirds, of participants. The two-thirds number appears because tolerating `f` Byzantine nodes requires `n >= 3f + 1` participants.
- **Gossip:** each node forwards what it learns to a few peers, so information spreads exponentially without a central coordinator.

#### Exercise 6.1: simulate a flaky network in one process

Build N goroutine "nodes" connected by channels. Write a `Network` wrapper that randomly delays, drops or duplicates messages. Implement gossip of a single value and measure how many rounds until all nodes have it, for different drop rates.

#### Exercise 6.2: watch consensus fail

Give each of 5 nodes a different proposed value and let them "agree" by taking whichever they hear first. Show with a flaky network that they end up with different values. Then add a coordinator (a leader that picks) and show what breaks if the leader crashes. These two failures motivate the next module.

**You must be able to explain:** the difference between crash and Byzantine faults; safety versus liveness; why 3f+1; why "just use a database" works when you trust the operator and fails when you do not.

---

### Module 7: Consensus (the heart of the subject)

#### The problem, stated precisely

A set of nodes, some possibly malicious, must agree on a single growing sequence of blocks. A consensus protocol should provide:

- **Agreement (safety):** honest nodes never finalise conflicting histories.
- **Validity:** only valid blocks (valid signatures, valid transactions) are accepted.
- **Liveness:** the chain keeps growing.

The central design question is: **who gets to propose the next block, and how does everyone else decide to accept it?** Four families answer it.

#### 7.1 Single leader / Proof of Authority (the ProjectX approach)

A fixed, known list of validators. One (or a rotating one, round-robin by height) is allowed to produce each block; its signature proves it. Simple, fast and deterministic, but it trusts the validator set. This is how permissioned and consortium chains work, and it is the right *first* thing to implement.

**Exercise 7.1:** extend your chain so a block is valid only if signed by the validator whose index equals `height % numValidators`. Show that a block from the wrong validator is rejected. Then show the failure mode: if that validator is offline, the chain stalls (a liveness problem). Add a timeout that skips to the next validator and state what new safety risk that creates.

#### 7.2 Proof of Work (Nakamoto consensus)

Bitcoin's idea. Anyone may propose a block, but to be valid its header hash must be below a **target**. Finding such a hash requires brute-forcing a `nonce` field, which costs real computation. Properties:

- Block production is a lottery weighted by computing power, not by identity. No membership list is needed (**permissionless**).
- **Difficulty adjustment:** the target is retuned periodically (Bitcoin targets about 10 minutes per block) so the block rate stays stable as total hash power changes.
- **Fork choice rule:** if two valid blocks appear at once (a *fork*), nodes follow the chain with the most accumulated work (loosely, "the longest chain"). Eventually one branch outgrows the other and the short one is abandoned (a *reorg*).
- **Probabilistic finality:** a transaction is never 100 percent final; it becomes exponentially harder to reverse with each block built on top, so people wait several confirmations.
- **The 51 percent attack:** an attacker with a majority of the work can out-build the honest chain and rewrite recent history (and double-spend). The cost of the attack is what secures the chain.
- **Incentive:** the miner who finds a block collects a block reward and fees. Spending real electricity makes dishonesty expensive and honesty profitable.

```go
func mine(header []byte, bits uint) (nonce uint64, hash [32]byte) {
    target := new(big.Int).Lsh(big.NewInt(1), 256-bits) // hash must be below 2^(256-bits)
    buf := make([]byte, len(header)+8)
    copy(buf, header)
    for nonce = 0; ; nonce++ {
        binary.BigEndian.PutUint64(buf[len(header):], nonce)
        hash = sha256.Sum256(buf)
        if new(big.Int).SetBytes(hash[:]).Cmp(target) < 0 {
            return nonce, hash
        }
    }
}
```

**Exercise 7.2:** (a) mine blocks at 16, 20 and 24 bits and time them, so you *feel* that each extra bit doubles the work; (b) implement `Verify` (one hash, instantly) and notice the asymmetry: hard to produce, trivial to check; (c) build two competing chains from the same parent and write `chooseChain` using total work; (d) write a difficulty adjustment that changes `bits` every N blocks based on measured time.

#### 7.3 Proof of Stake

Replace computation with **locked-up money**. Validators put coins at stake; the protocol selects proposers (randomly, weighted by stake) and has other validators vote. Misbehaviour such as signing two conflicting blocks is punished by **slashing** (destroying stake). Security comes from the cost of losing stake, not from burning electricity. It is far more energy-efficient, but has its own subtle problems (such as "nothing at stake", long-range attacks and the need for a careful randomness source), which is why real designs are complicated.

#### 7.4 BFT-style voting (Tendermint, PBFT family)

A known validator set runs rounds: a proposer sends a block, validators **vote** in two phases, and if more than two thirds agree the block is **final immediately**. No forks in normal operation. This is where the 3f+1 rule from module 6 shows up. The trade-off: it needs a known validator set and many messages per block, so it scales to tens or hundreds of validators, not millions. Cosmos chains use this style.

#### Choosing between them

| Property | PoA | PoW | PoS | BFT voting |
| --- | --- | --- | --- | --- |
| Who can validate | fixed list | anyone with hardware | anyone with stake | known set (often stake-weighted) |
| Finality | immediate (trusted) | probabilistic | economic or immediate | immediate |
| Energy use | tiny | large | tiny | tiny |
| Complexity to build | lowest | low | high | high |
| Trust assumption | the operators | majority honest hash power | majority honest stake | fewer than a third Byzantine |

**You must be able to explain:** why proof of work has to be expensive to produce but cheap to verify; what a fork is and how it resolves; why finality differs between PoW and BFT; what each approach assumes about the attacker.

---

### Module 8: Peer-to-peer networking

The chain is useless if nodes cannot exchange data. This is also the module where the ProjectX "Transport" interface will make complete sense.

#### 8.1 Building blocks

- **TCP in Go:** `net.Listen`, `Accept`, `net.Dial`, one goroutine per connection.
- **Message framing:** TCP is a stream, not a message boundary. You must frame messages yourself, usually with a **length prefix**: `[4 bytes length][1 byte type][payload]`. Use `io.ReadFull` to read exactly n bytes and always enforce a maximum message size, or one peer can exhaust your memory.
- **Handshake:** exchange version, network ID, genesis hash and current height when two nodes connect, so incompatible nodes disconnect immediately.
- **Peer management:** track connected peers, remove dead ones, limit the connection count.
- **Discovery:** start from hard-coded *bootstrap nodes*, ask peers for more peers, and connect. Real networks use structured protocols (for example Kademlia DHTs).

#### 8.2 Gossip and sync

- **Transaction gossip:** receive a tx, validate, ignore if already known, store, forward to peers. The "ignore if known" step prevents infinite loops.
- **Block gossip:** the same, for blocks.
- **Initial sync:** a new node starts at genesis, asks a peer for its height, then requests missing blocks in ranges and validates each as it arrives. Do not trust the peer; verify everything.

#### Exercise 8.1: framed messages

Write `WriteMsg(w io.Writer, typ byte, payload []byte) error` and `ReadMsg(r io.Reader) (typ byte, payload []byte, err error)` with a 1 MB limit. Test with a reader that returns one byte at a time (use `iotest.OneByteReader`) to prove you handle partial reads.

#### Exercise 8.2: three-node gossip

Start three TCP nodes that each connect to one other. Submit a transaction to node 1 and watch all three pools receive it exactly once. Log duplicates dropped.

#### Exercise 8.3: sync

Run node A, mine 50 blocks, then start empty node B pointed at A and verify B reaches height 50 with an identical tip hash.

**You must be able to explain:** why length-prefixing is required; how gossip avoids amplification; why a syncing node cannot trust blindly; what a handshake protects against.

---

### Module 9: The mempool, fees and incentives

- **Mempool:** each node keeps a pool of valid, unconfirmed transactions. The block producer chooses which to include.
- **Why fees exist:** block space is scarce, and validators or miners need payment. Transactions compete: higher fee, earlier inclusion. Without fees, spam is free and the chain can be flooded.
- **Ordering power:** whoever builds the block chooses the order, which can be worth money (reordering, front-running). This is called **MEV** (miner or maximal extractable value). Just know it exists and why it matters for fairness.
- **Inflation and rewards:** many chains create new coins as a block reward (the *coinbase* transaction; this is the "coinbase" in the ProjectX series). Rewards bootstrap security before fees are large.
- **Game theory mindset:** the right question for every protocol rule is, "If every participant maximises their own profit, does the system still behave?"

**Exercise 9.1:** give your mempool a per-transaction fee, order by fee per byte, cap the block size, and show that low-fee transactions wait. Then add per-account nonce ordering (a tx with nonce 5 cannot be included before nonce 4) and explain why that makes priority ordering more complicated.

---

### Module 10: Execution and smart contracts

#### The idea

If `apply(state, tx)` is a fixed function ("subtract from A, add to B"), you have a money ledger. If `apply` is *a virtual machine running code supplied inside the transaction*, you have a **general-purpose, programmable, shared computer**. That code is a *smart contract*: a program stored on-chain, with its own persistent storage, that anyone can call and that executes identically on every node.

#### Requirements for such a VM

- **Deterministic:** no clocks, no randomness, no network, no filesystem. Everything it can see comes from the transaction and the chain state.
- **Sandboxed:** contract code is hostile by default and must not escape.
- **Metered:** an infinite loop would freeze the network, so each instruction costs **gas**; a transaction states a gas limit, the VM stops at the limit, and the sender pays for what was used. This also prices computation fairly.
- **Atomic:** if execution fails, its state changes are rolled back.

#### Stack machines in thirty seconds

Programs are byte arrays of opcodes. Operands live on a stack. `PUSH 3, PUSH 2, ADD` leaves 5. It is simple to implement and verify, which is why the EVM, the JVM and WebAssembly are all stack-based.

#### Exercise 10.1: a tiny VM with gas

Implement opcodes `PUSH`, `ADD`, `SUB`, `MUL`, `JUMP`, `JUMPI`, `STORE`, `LOAD`, `HALT`. Give each a gas cost. Run a program with an infinite loop and prove it halts with an out-of-gas error. Then make `STORE` write to a `map[string]uint64` and show a failed execution does not leave partial writes (snapshot and restore, or buffer writes and commit at the end).

**Know the risks:** contract bugs are permanent and public. Reentrancy, integer overflow and access-control mistakes have cost real money (the 2016 DAO incident is the canonical story). That is a strong reason to keep early contract logic minimal.

---

### Module 11: Storage

- **In memory first.** Slices and maps are fine to start.
- **Persistence:** blocks are append-only, so a simple file-per-segment or a key-value store works. Chain data and state are usually in an embedded key-value database (for example LevelDB or RocksDB families; in Go, BoltDB-like stores are common). For learning, write an append-only log file with a length-prefixed record format yourself first.
- **State needs a different structure than blocks.** State changes every block and you need to prove "the balance of X at block N is Y". Ethereum uses a **Merkle-Patricia trie** so the entire state has a single root hash included in the block header. Clients can then verify any piece of state with a Merkle proof against that root. You do not need to build a trie in version 1, but understand what it is for.
- **Pruning and snapshots:** full history grows forever. Real nodes prune old state or sync from snapshots.
- **Indexing:** `hash -> block`, `height -> hash`, `tx hash -> block` lookups are separate indexes.

**Exercise 11.1:** write blocks to disk, kill the process, restart, and rebuild the chain by replaying the file, verifying every hash on the way in. Then truncate the last few bytes of the file to simulate a crash mid-write and make your loader recover safely.

---

### Module 12: Security thinking

Blockchains are adversarial systems: assume every input comes from an attacker. A checklist you should be able to reason about:

| Threat | What happens | Typical defence |
| --- | --- | --- |
| Replay | an old signed tx is resubmitted | nonce, chain ID |
| Signature malleability | same tx, different valid signature bytes, so a different hash | canonical signatures, hash only canonical data |
| Double spend | conflicting txs | consensus and finality rules |
| 51 percent or validator takeover | history rewritten | cost of attack, fault tolerance threshold |
| Sybil attack | one actor fakes many identities | cost per identity (work, stake) |
| Eclipse attack | all of a node's peers are attacker-controlled | diverse and random peer selection |
| DoS: oversized or malformed messages | node crashes or stalls | size limits, validate cheaply first, rate limits |
| DoS: expensive transactions | VM spins | gas metering |
| Consensus divergence bug | nodes compute different states | determinism and heavy testing |
| Key theft | funds stolen | key management, hardware wallets |
| Smart contract bugs | funds drained | audits, simpler contracts, formal methods |

A good habit while building: for every function that takes remote input, ask "what is the most hostile input possible, and what is the cheapest check I can do first?" Order your validation from cheap (length, type) to expensive (signature, VM execution).

---

### Module 13: What blockchains are for (and not for)

**Where the trade-offs can pay off:**

- **Digital cash and value transfer** without an issuing intermediary.
- **Programmable assets:** tokens, stablecoins, NFTs, tickets, loyalty points.
- **Open finance:** exchanges, lending and derivatives implemented as public contracts anyone can audit and call.
- **Shared records between organisations** that do not want one party to be the system of record (supply chains, settlement between institutions, registries).
- **Verifiable timestamping and provenance:** proving a document or dataset existed and was not changed.
- **Censorship resistance** for people who cannot rely on a local institution.
- **Coordination systems:** DAOs and on-chain voting (with serious governance caveats).

**Where a normal database is better:** one organisation controls the data; you need high throughput and low latency; you need to delete or correct data (GDPR-style erasure conflicts with immutability); data is private and confidentiality matters more than auditability.

**A quick decision test.** A blockchain is worth considering only if: (1) several parties write to shared state, (2) they do not fully trust each other or any single operator, (3) no trusted intermediary can or should be placed in the middle, and (4) a public audit trail is a benefit and not a liability. If any answer is no, use a database.

**Known limits to be honest about:** low throughput compared with centralised systems (the *scalability trilemma* of decentralisation, security and scale), high latency to finality, transparency that conflicts with privacy, irreversible mistakes, and a lot of hype, speculation and fraud in the surrounding ecosystem. Understanding the limits is part of understanding the technology.

---

### Module 14: Go skills you need before you start

| Skill | Used for |
| --- | --- |
| Interfaces and dependency injection | `Transport`, `Validator`, `Storage` |
| Goroutines, channels, `select` | server main loop, per-peer readers |
| `sync.Mutex` / `RWMutex`, `sync/atomic` | chain, pool, peer map |
| `context.Context` | shutdown and timeouts |
| `io.Reader` / `io.Writer`, `bufio`, `io.ReadFull` | framing and encoding |
| `encoding/binary`, `encoding/gob`, `encoding/json` | serialisation |
| `crypto/sha256`, `crypto/ed25519`, `crypto/ecdsa`, `crypto/rand` | hashing and signatures (never `math/rand` for keys) |
| `math/big` | difficulty targets and big integers |
| `net`, `net/http` | P2P and API |
| `testing`, table-driven tests, `-race`, fuzzing (`go test -fuzz`) | correctness of decoders and validators |
| Error wrapping (`%w`, `errors.Is`) | meaningful validation errors |
| `go vet`, `gofmt` | hygiene |

Two Go-specific traps to learn now: **never ranging over a map where order matters**, and **data races in a shared chain structure**. Run every test with `-race`.

---

### Module 15: The capstone ladder (your own primitive blockchain)

Build these in order. Each stage should compile, pass its tests and be demo-able before you move on. Each one corresponds to modules above and, afterwards, to the ProjectX videos in section 10.

| Stage | Build | Proves you understand | Then watch |
| --- | --- | --- | --- |
| 1 | Hash chain with `Validate()` | modules 1 and 3 | videos 2, 5 |
| 2 | Merkle root in the header | module 3 | video 2 (DataHash) |
| 3 | Keypairs and signed transactions | module 2 | videos 3, 4 |
| 4 | Canonical encoding and tx hashing | module 4 | videos 2, 4 |
| 5 | Account state with nonces and `Apply` | module 5 | videos 25, 26 |
| 6 | Block validator (height, prev hash, signatures) | modules 3 and 7 | video 6 |
| 7 | Mempool with dedupe and ordering | module 9 | videos 7, 8 |
| 8 | In-process multi-node network with a `Transport` interface | module 6 | video 1 |
| 9 | Single-validator block production on a timer (PoA) | module 7.1 | videos 11, 12 |
| 10 | Gossip of txs and blocks | module 8 | videos 9, 10, 13 |
| 11 | TCP transport with framing and handshake | module 8 | video 19 |
| 12 | Chain sync for late joiners | module 8 | videos 18, 20 |
| 13 | Proof of work as an alternative producer, with fork choice | module 7.2 | not in the series |
| 14 | Tiny VM with gas and contract storage | module 10 | videos 14 to 17 |
| 15 | Persistence to disk with crash recovery | module 11 | not in the series |
| 16 | HTTP/JSON API | module 14 | videos 22, 23 |

Stages 13 and 15 are not in the series. They are your own work, and they are the ones that turn watching into understanding.

**Suggested pacing**

- Weeks 1 to 2: modules 0 to 3, stages 1 to 3
- Weeks 3 to 4: modules 4 to 5, stages 4 to 6
- Weeks 5 to 6: modules 6 to 8, stages 7 to 10
- Weeks 7 to 8: modules 7.2, 9, 10, stages 11 to 14
- Weeks 9 to 10: modules 11 to 13, stages 15 to 16, and the security review
- Weeks 11 to 12: re-watch the series with your own code open and diff the designs

---

### The "100 percent" self-test

You understand blockchains when you can answer all of these from memory, with code or a whiteboard, without notes:

1. What problem does a blockchain solve that a database does not, and when is a database the better answer?
2. Why is the order of transactions the real problem, and how does a double spend show it?
3. Walk a transaction from a user's wallet to being final, naming every component it touches.
4. What exactly does the hash of a block cover, and how does that make history tamper-evident? What does it *not* protect against?
5. How does a Merkle proof work, and why can a light client verify a payment without the full chain?
6. Why must every operation that affects state be deterministic? Name five ways Go code could accidentally violate that.
7. Explain Proof of Work, Proof of Authority, Proof of Stake and BFT voting: who proposes, how others accept, what finality looks like, and what the attacker must control.
8. What is a fork, and how does your node decide which branch to follow?
9. How does a brand-new node join a network and trust what it downloads?
10. What is gas for, and what would happen without it?
11. Describe three attacks against your own implementation and the code that stops each.
12. Which parts of your design would not scale, and how would a production chain address each?

---

### After you have built your own: industry tools and how they map

Only after the capstone, look at the following. Because you built the primitive version, each will read as "their version of my component", not as magic.

| Your component | Production equivalents to study |
| --- | --- |
| Whole node, execution and account model | Ethereum clients (such as go-ethereum), the EVM, Solidity |
| Consensus | CometBFT (Tendermint family), Ethereum's proof-of-stake protocol, Bitcoin's PoW |
| Application framework | Cosmos SDK, Substrate (Rust) |
| P2P | libp2p, Kademlia DHTs, gossipsub |
| Serialisation | Protobuf, RLP, SSZ |
| Storage | LevelDB, RocksDB, Pebble, Merkle-Patricia and Verkle tries |
| Virtual machines | EVM, WebAssembly runtimes, Move VM |
| Scaling | rollups (optimistic and zero-knowledge), data availability layers, sharding |
| Cryptography beyond signatures | threshold and BLS signatures, zero-knowledge proofs |

The best next reads are the Bitcoin whitepaper (9 pages), the Ethereum whitepaper and the Ethereum yellow paper's overview, and the Tendermint paper. With your own implementation behind you, they will be readable.
