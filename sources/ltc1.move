module nplex::ltc1 {
    use nplex::registry::{Self, NPLEXRegistry};

    // ==================== Structs ====================

    /// The OTW for package initialization
    public struct LTC1 has drop {}

    /// The Witness for Registry Binding
    public struct LTC1Witness has drop {}

    /// The LTC1 Contract Object
    public struct LTC1Contract has key, store {
        id: iota::object::UID,
        document_hash: vector<u8>,
        buyer: address,
        seller: address,
    }

    // ==================== Initialization ====================

    fun init(otw: LTC1, _ctx: &mut iota::tx_context::TxContext) {
        let _ = otw;
    }

    // ==================== Public Functions ====================

    public entry fun create_contract(
        registry: &mut NPLEXRegistry,
        document_hash: vector<u8>,
        buyer: address,
        seller: address,
        ctx: &mut iota::tx_context::TxContext
    ) {
        // 1. Claim hash
        let claim = registry::claim_hash(registry, document_hash);

        // 2. Create UID
        let contract_uid = iota::object::new(ctx);
        let contract_id = iota::object::uid_to_inner(&contract_uid);

        // 3. Bind hash with Witness
        registry::bind_executor(
            registry, 
            claim, 
            contract_id, 
            LTC1Witness {}
        );

        // 4. Create and transfer
        let contract = LTC1Contract {
            id: contract_uid,
            document_hash: document_hash,
            buyer,
            seller,
        };
        iota::transfer::public_transfer(contract, seller);
    }
}
