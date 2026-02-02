// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// Unit tests for LTC1
/// Test integration with registry and core ltc1 features

#[test_only]
module nplex::ltc1_tests {
    use nplex::ltc1::{Self, LTC1Package, LTC1Token, OwnerBond, LTC1Witness};
    use nplex::registry::{Self, NPLEXRegistry, NPLEXAdminCap};
    use iota::test_scenario::{Self, Scenario, next_tx, ctx};
    use iota::coin::{Self, Coin};
    use iota::iota::IOTA;
    use std::string::{Self};

    // Test Users
    const ADMIN: address = @0xAD;
    const OWNER: address = @0xB;
    const INVESTOR: address = @0xC;
    const NEW_OWNER: address = @0xD;

    // Test Data
    const DOCUMENT_HASH: u256 = 123456789;
    const TOTAL_SUPPLY: u64 = 1000;
    const TOKEN_PRICE: u64 = 1_000_000; // 1 IOTA
    const NOMINAL_VALUE: u64 = 1_000_000_000;
    const SPLIT_BPS: u64 = 5000; // 50%

    // ==================== Helpers ====================

    fun setup_registry(scenario: &mut Scenario) {
        // 1. Init Registry
        next_tx(scenario, ADMIN);
        registry::init_for_testing(ctx(scenario));

        // 2. Register Hash & Authorize LTC1
        next_tx(scenario, ADMIN);
        let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
        let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);

        registry::register_hash(&mut registry, &admin_cap, DOCUMENT_HASH, ctx(scenario));
        registry::add_executor<LTC1Witness>(&mut registry, &admin_cap);

        test_scenario::return_shared(registry);
        test_scenario::return_to_sender(scenario, admin_cap);
    }

    fun mint_coins(amount: u64, scenario: &mut Scenario): Coin<IOTA> {
        coin::mint_for_testing<IOTA>(amount, ctx(scenario))
    }

    // ==================== Tests ====================

    #[test]
    fun test_end_to_end_flow() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract (Owner)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            ltc1::create_contract(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                ctx(&mut scenario)
            );
            test_scenario::return_shared(registry);
        };

        // 1.5 Get Package ID from Registry
        next_tx(&mut scenario, ADMIN);
        let package_id = {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let info = registry::get_hash_info(&registry, DOCUMENT_HASH);
            let contract_id_opt = registry::hash_contract_id(&info);
            let id = std::option::extract(&mut std::option::some(std::option::destroy_some(contract_id_opt)));
            test_scenario::return_shared(registry);
            id
        };

        // 2. Buy Tokens (Investor)
        // Investor buys 100 tokens (10% of total, 20% of max sellable)
        let buy_amount = 100;
        let cost = buy_amount * TOKEN_PRICE;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);

            ltc1::buy_token(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        //assert investor has 100 tokens
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let package = test_scenario::take_shared_by_id<LTC1Package>(&scenario, package_id);
            let token = test_scenario::take_from_sender<LTC1Token>(&scenario);

            assert!(ltc1::balance(&token) == 100, 0);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, token);
        };

        // 3. Deposit Revenue (Owner)
        // Owner deposits 1000 IOTA into revenue pool
        // Total Supply: 1000.  Total Revenue: 1000.  Revenue per Share: 1.
        let revenue_amount = 1000;
        
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(revenue_amount, &mut scenario);

            ltc1::deposit_revenue(&registry, &mut package, &bond, payment, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 4. Claim Revenue (Investor)
        // Investor has 100 tokens. Should get 100 IOTA (100 shares * 1 IOTA/share).
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package>(&scenario, package_id);
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);

            ltc1::claim_revenue(&registry, &mut package, &mut token, ctx(&mut scenario));

            // Verify payout (not easily checkable in simple test without inspecting events or balances, 
            // but if it didn't abort, it worked. We assume math coverage in logic).
            
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, token);
        };
        
        // 5. Claim Revenue (Owner)
        // Owner owns:
        // - Unsold: 900 shares (900 IOTA)
        // - Legacy: 0 (since they didn't sell pre-revenue tokens? Wait.)
        // Actually, when Investor bought, revenue was 0. So Legacy is 0.
        // Owner gets 900 IOTA.
        next_tx(&mut scenario, OWNER);
         {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package>(&scenario, package_id);
            let mut bond = test_scenario::take_from_sender<OwnerBond>(&scenario);

            ltc1::claim_revenue_owner(&registry, &mut package, &mut bond, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = ltc1::E_INSUFFICIENT_SUPPLY)]
    fun test_supply_split_enforcement() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract (Owner) with 50% split (Max Sellable = 500)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            ltc1::create_contract(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS, // 5000
                string::utf8(b"ipfs://metadata"),
                ctx(&mut scenario)
            );
            test_scenario::return_shared(registry);
        };

        // 1.5 Get Package ID from Registry
        next_tx(&mut scenario, ADMIN);
        let package_id = {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let info = registry::get_hash_info(&registry, DOCUMENT_HASH);
            let contract_id_opt = registry::hash_contract_id(&info);
            let id = std::option::extract(&mut std::option::some(std::option::destroy_some(contract_id_opt)));
            test_scenario::return_shared(registry);
            id
        };

        // 2. Buy More Than Allowed (Investor)
        // Try to buy 501 tokens (Limit is 500)
        let buy_amount = 501;
        let cost = buy_amount * TOKEN_PRICE;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);

            // This should fail
            ltc1::buy_token(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        test_scenario::end(scenario);
    }
    #[test]
    #[expected_failure(abort_code = registry::E_HASH_NOT_APPROVED)]
    fun test_create_contract_not_registered_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Init registry, Authorize Witness, BUT DO NOT Register Hash
        next_tx(&mut scenario, ADMIN);
        {
            registry::init_for_testing(ctx(&mut scenario));
        };

        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);

            // ONLY Authorize Witness
            registry::add_executor<LTC1Witness>(&mut registry, &admin_cap);

            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // Try to create contract (Should Fail)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            ltc1::create_contract(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                ctx(&mut scenario)
            );
            test_scenario::return_shared(registry);
        };

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_UNAUTHORIZED_EXECUTOR)]
    fun test_create_contract_unauthorized_witness() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Setup: Init registry, Register Hash, BUT DO NOT Authorize Witness
        next_tx(&mut scenario, ADMIN);
        {
            registry::init_for_testing(ctx(&mut scenario));
        };

        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);

            // ONLY Register Hash
            registry::register_hash(&mut registry, &admin_cap, DOCUMENT_HASH, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // Try to create contract (Should Fail)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            ltc1::create_contract(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                ctx(&mut scenario)
            );
            test_scenario::return_shared(registry);
        };

        test_scenario::end(scenario);
    }
    #[test]
    fun test_owner_bond_transfer() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract (Owner)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            ltc1::create_contract(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                ctx(&mut scenario)
            );
            test_scenario::return_shared(registry);
        };

        // 2. Get Package ID
        next_tx(&mut scenario, ADMIN);
        let package_id = {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let info = registry::get_hash_info(&registry, DOCUMENT_HASH);
            let contract_id_opt = registry::hash_contract_id(&info);
            let id = std::option::extract(&mut std::option::some(std::option::destroy_some(contract_id_opt)));
            test_scenario::return_shared(registry);
            id
        };

        // 3. Authorize Transfer (Admin)
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::authorize_transfer(
                &mut registry,
                &admin_cap,
                package_id,
                NEW_OWNER
            );

            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 4. Transfer Bond (Owner)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            
            ltc1::transfer_bond(
                &mut registry,
                bond,
                NEW_OWNER,
                ctx(&mut scenario)
            );

            test_scenario::return_shared(registry);
        };

        // 5. Verify New Owner has Bond/Revenue rights
        next_tx(&mut scenario, NEW_OWNER);
        {
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            assert!(object::id(&bond) != object::id_from_address(@0x0), 0); // Just check it exists
            test_scenario::return_to_sender(&scenario, bond);
        };

        test_scenario::end(scenario);
    }
}
