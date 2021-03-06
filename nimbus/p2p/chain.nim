import ../db/db_chain, eth/common, chronicles, ../vm_state, ../vm_types,
  ../vm/[computation, message], stint, nimcrypto,
  ../utils, eth/trie/db, ../tracer, ./executor

type
  Chain* = ref object of AbstractChainDB
    db: BaseChainDB

proc newChain*(db: BaseChainDB): Chain =
  result.new
  result.db = db

method genesisHash*(c: Chain): KeccakHash {.gcsafe.} =
  c.db.getBlockHash(0.toBlockNumber)

method getBlockHeader*(c: Chain, b: HashOrNum, output: var BlockHeader): bool {.gcsafe.} =
  case b.isHash
  of true:
    c.db.getBlockHeader(b.hash, output)
  else:
    c.db.getBlockHeader(b.number, output)

method getBestBlockHeader*(c: Chain): BlockHeader {.gcsafe.} =
  c.db.getCanonicalHead()

method getSuccessorHeader*(c: Chain, h: BlockHeader, output: var BlockHeader, skip = 0'u): bool {.gcsafe.} =
  let offset = 1 + skip.toBlockNumber
  if h.blockNumber <= (not 0.toBlockNumber) - offset:
    result = c.db.getBlockHeader(h.blockNumber + offset, output)

method getAncestorHeader*(c: Chain, h: BlockHeader, output: var BlockHeader, skip = 0'u): bool {.gcsafe.} =
  let offset = 1 + skip.toBlockNumber
  if h.blockNumber >= offset:
    result = c.db.getBlockHeader(h.blockNumber - offset, output)

method getBlockBody*(c: Chain, blockHash: KeccakHash): BlockBodyRef =
  result = nil

method persistBlocks*(c: Chain, headers: openarray[BlockHeader], bodies: openarray[BlockBody]): ValidationResult =
  # Run the VM here
  if headers.len != bodies.len:
    debug "Number of headers not matching number of bodies"
    return ValidationResult.Error

  let transaction = c.db.db.beginTransaction()
  defer: transaction.dispose()

  trace "Persisting blocks", fromBlock = headers[0].blockNumber, toBlock = headers[^1].blockNumber
  for i in 0 ..< headers.len:
    let head = c.db.getCanonicalHead()
    let vmState = newBaseVMState(head.stateRoot, headers[i], c.db)
    let validationResult = processBlock(c.db, headers[i], bodies[i], vmState)

    when not defined(release):
      if validationResult == ValidationResult.Error and
          bodies[i].transactions.calcTxRoot == headers[i].txRoot:
        dumpDebuggingMetaData(c.db, headers[i], bodies[i], vmState)
        warn "Validation error. Debugging metadata dumped."

    if validationResult != ValidationResult.OK:
      return validationResult

    discard c.db.persistHeaderToDb(headers[i])
    if c.db.getCanonicalHead().blockHash != headers[i].blockHash:
      debug "Stored block header hash doesn't match declared hash"
      return ValidationResult.Error

    c.db.persistTransactions(headers[i].blockNumber, bodies[i].transactions)
    c.db.persistReceipts(vmState.receipts)

  transaction.commit()

method getTrieDB*(c: Chain): TrieDatabaseRef {.gcsafe.} =
  c.db.db

