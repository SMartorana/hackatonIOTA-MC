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
    use iota::clock;
    use std::string::{Self};

    // Test Users
    const ADMIN: address = @0xAD;
    const OWNER: address = @0xB;
    const INVESTOR: address = @0xC;
    const INVESTOR2: address = @0xE;
    const NEW_OWNER: address = @0xD;

    // Test Data
    const DOCUMENT_HASH: u256 = 123456789;
    const TOTAL_SUPPLY: u64 = 1_000_000_000;
    const TOKEN_PRICE: u64 = 1_000; // (0.000001 IOTA)
    const NOMINAL_VALUE: u64 = 1_000_000_000;
    const SPLIT_BPS: u64 = 500_000; // 50.0000%

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

    // Test end to end flow
    // Arrange: Initialize the registry, register the document hash, and authorize the LTC1 witness.
    // Act: Create the LTC1 contract, mint tokens, and perform investment transactions.
    // Assert: Verify the total supply, token balances, and correct distribution of funds.
    // Scenario: An LTC1 is issued with 1B tokens and price of 1,000 NANOS (1 MICRON).
    // 100k tokens are sold to investor 1, 200k tokens are sold to investor 2.
    // Owner deposits 1M NANOS into revenue pool.
    // Investor 1 must claim 100 nano, investor 2 claims 200 nano, owner claims 999,700 nano.
    #[test]
    fun test_end_to_end_flow() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract (Owner)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
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
        // Total Supply: 1,000,000,000
        // Max Sellable: 500,000,000 (50%)
        // Investor buys 100,000 tokens (0.01% of total, 0.02% of max sellable)
        let buy_amount = 100_000;
        let cost = buy_amount * TOKEN_PRICE;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);

            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 2.5 Buy Tokens (Investor 2)
        // Investor2 buys 200,000 tokens
        let buy_amount_2 = 200_000;
        let cost_2 = buy_amount_2 * TOKEN_PRICE;
        
        next_tx(&mut scenario, INVESTOR2);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(cost_2, &mut scenario);

            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount_2, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        //assert investor has 100,000 tokens
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let token = test_scenario::take_from_sender<LTC1Token>(&scenario);

            assert!(ltc1::balance(&token) == 100_000, 0);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, token);
        };

        // 3. Deposit Revenue (Owner)
        // Owner deposits 1,000,000 NANOS (0.001 IOTA) into revenue pool
        // Total Supply: 1B.  Total Revenue: 1M NANOS.
        let revenue_amount = 1_000_000;
        
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(revenue_amount, &mut scenario);

            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, payment, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 4. Claim Revenue (Investor)
        // Investor has 100,000 tokens (0.01% of Total Supply)
        // Revenue Pool: 1,000,000 NANOS
        // Share: 100,000 / 1,000,000,000 * 1,000,000 = 100 NANOS
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);

            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, token);
        };

        // 4.5 Verify Investor Revenue (100 NANOS)
        next_tx(&mut scenario, INVESTOR);
        {
            let revenue = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(iota::coin::value(&revenue) == 100, 1);
            test_scenario::return_to_sender(&scenario, revenue);
        };

        // 4.6 Claim Revenue (Investor 2)
        next_tx(&mut scenario, INVESTOR2);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);

            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, token);
        };

        // 4.7 Verify Investor 2 Revenue (200 NANOS)
        next_tx(&mut scenario, INVESTOR2);
        {
            let revenue = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(iota::coin::value(&revenue) == 200, 3);
            test_scenario::return_to_sender(&scenario, revenue);
        };
        
        // 5. Claim Revenue (Owner)
        // Owner owns remaining shares: 1,000,000,000 - 300,000 = 999,700,000 (99.97%)
        // Legacy Revenue: 0
        // Share: 999,700,000 / 1,000,000,000 * 1,000,000 = 999,700 NANOS
        next_tx(&mut scenario, OWNER);
         {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let mut bond = test_scenario::take_from_sender<OwnerBond>(&scenario);

            ltc1::claim_revenue_owner<IOTA>(&registry, &mut package, &mut bond, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 5.5 Verify Owner Revenue (999,700 NANOS)
        next_tx(&mut scenario, OWNER);
        {
            let revenue = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(iota::coin::value(&revenue) == 999_700, 2);
            test_scenario::return_to_sender(&scenario, revenue);
        };

        test_scenario::end(scenario);
    }

    // Test supply split enforcement
    // Arrange: Create a contract with 50% split (Max Sellable = 50% of supply).
    // Act: Investor tries to buy 50% + 1 token.
    // Assert: Transaction aborts with E_INSUFFICIENT_SUPPLY.
    // Scenario: Creator sets 50% split (5000 bps). Total supply 1B. Max sellable 500M.
    // Investor tries to buy 500,000,001 tokens. Implementation must block this.
    #[test]
    #[expected_failure(abort_code = ltc1::E_INSUFFICIENT_SUPPLY)]
    fun test_supply_split_enforcement() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract (Owner) with 50% split (Max Sellable = 500)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS, // 5000
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
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
        // Try to buy 500_000_001 tokens (Limit is 500_000_000)
        let buy_amount = 500_000_001;
        let cost = buy_amount * TOKEN_PRICE;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);

            // This should fail
            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        test_scenario::end(scenario);
    }
    // Test contract creation with unregistered hash
    // Arrange: Registry initialized, witness authorized, but HASH NOT REGISTERED.
    // Act: Creator attempts to create contract with this hash.
    // Assert: Transaction aborts with E_HASH_NOT_APPROVED.
    // Scenario: Admin forgets to register document hash. Creator calls create_contract.
    // System must reject the creation attempt.
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
            let clock = clock::create_for_testing(ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };

        test_scenario::end(scenario);
    }

    // Test contract creation with unauthorized witness
    // Arrange: Registry initialized, hash registered, but WITNESS NOT AUTHORIZED.
    // Act: Creator attempts to create contract using this witness type.
    // Assert: Transaction aborts with E_UNAUTHORIZED_EXECUTOR.
    // Scenario: Hash is valid, but the contract type (LTC1) was not allowlisted by Admin.
    // System must reject binding this contract type to the hash.
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
            let clock = clock::create_for_testing(ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };

        test_scenario::end(scenario);
    }
    // Test owner bond transfer
    // Arrange: Contract created. Admin authorizes transfer of Bond to NEW_OWNER.
    // Act: Owner calls transfer_bond.
    // Assert: Bond is successfully moved to NEW_OWNER.
    // Scenario: Owner sells the deal to another servicer. Admin approves the transfer.
    // Original Owner executes transfer. New Owner receives the Bond object.
    #[test]
    fun test_owner_bond_transfer() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract (Owner)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
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
    // Test withdraw funding
    // Arrange: Investor buys tokens, funding the pool.
    // Act: Owner withdraws the raised capital using OwnerBond.
    // Assert: Owner's coin balance increases by the withdrawn amount.
    // Scenario: 100k tokens sold for 100,000,000 NANOS (0.1 IOTA). Pool has 100M NANOS.
    // Owner withdraws 100M NANOS. Owner receives 100M NANOS.
    #[test]
    fun test_withdraw_funding() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract (Owner)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };

        // 1.5 Get Package ID
        next_tx(&mut scenario, ADMIN);
        let package_id = {
             let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let info = registry::get_hash_info(&registry, DOCUMENT_HASH);
            let contract_id_opt = registry::hash_contract_id(&info);
            let id = std::option::extract(&mut std::option::some(std::option::destroy_some(contract_id_opt)));
            test_scenario::return_shared(registry);
            id
        };

        // 2. Buy Tokens (Investor) -> Funds the pool
        let buy_amount = 100_000;
        let cost = buy_amount * TOKEN_PRICE; 
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);

            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 3. Withdraw Funding (Owner)
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);

            ltc1::withdraw_funding<IOTA>(&registry, &mut package, &bond, cost, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };
        
        // 4. Verify Owner Balance
        next_tx(&mut scenario, OWNER);
        {
            let withdrawn_coin = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(iota::coin::value(&withdrawn_coin) == cost, 0);
            test_scenario::return_to_sender(&scenario, withdrawn_coin);
        };

        test_scenario::end(scenario);
    }
    // Test Complex Lifecycle Flow
    // Scenario:
    // 1. Funding: Investor buys 100k tokens (Costs 100M NANOS).
    // 2. Withdrawal: Owner withdraws the 100M NANOS funding.
    // 3. Handover: Owner transfers Bond to NEW_OWNER (with Admin approval).
    // 4. Revenue 1: NEW_OWNER deposits 1M NANOS revenue.
    // 5. Claim 1: Investor claims revenue (expect 100 NANOS).
    // 6. Secondary Market: Investor transfers tokens to INVESTOR2.
    // 7. Revenue 2: NEW_OWNER deposits another 1M NANOS.
    // 8. Claim 2: INVESTOR2 claims revenue (expect 100 NANOS).
    #[test]
    fun test_complex_lifecycle_flow() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract (Owner)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };

        // 1.5 Get Package ID
        next_tx(&mut scenario, ADMIN);
        let package_id = {
             let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let info = registry::get_hash_info(&registry, DOCUMENT_HASH);
            let contract_id_opt = registry::hash_contract_id(&info);
            let id = std::option::extract(&mut std::option::some(std::option::destroy_some(contract_id_opt)));
            test_scenario::return_shared(registry);
            id
        };

        // 2. Funding: Investor buys 100k tokens
        // Cost: 100,000 * 1,000 = 100,000,000 NANOS (0.1 IOTA)
        let buy_amount = 100_000;
        let cost = buy_amount * TOKEN_PRICE; 
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);

            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 3. Withdrawal: Owner withdraws funding
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);

            ltc1::withdraw_funding<IOTA>(&registry, &mut package, &bond, cost, ctx(&mut scenario));
            
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // Verify Owner actually got the money
        next_tx(&mut scenario, OWNER);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(iota::coin::value(&cash) == cost, 0);
            test_scenario::return_to_sender(&scenario, cash);
        };

        // 4. Handover: Authorize Transfer (Admin)
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::authorize_transfer(&mut registry, &admin_cap, package_id, NEW_OWNER);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 5. Handover: Transfer Bond (Owner -> NEW_OWNER)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            ltc1::transfer_bond(&mut registry, bond, NEW_OWNER, ctx(&mut scenario));
            test_scenario::return_shared(registry);
        };

        // 6. Revenue 1: NEW_OWNER deposits 1M NANOS
        // Total Revenue: 1,000,000
        let revenue_amount_1 = 1_000_000;
        next_tx(&mut scenario, NEW_OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(revenue_amount_1, &mut scenario);

            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, payment, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 7. Claim 1: INVESTOR claims
        // Share: 100k / 1B = 0.01%
        // payout = 1M * 0.01% = 100 NANOS
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);

            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, token);
        };

        // Verify Claim 1
        next_tx(&mut scenario, INVESTOR);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(iota::coin::value(&cash) == 100, 1);
            test_scenario::return_to_sender(&scenario, cash);
        };

        // 8. Secondary Market: INVESTOR -> INVESTOR2
        next_tx(&mut scenario, INVESTOR);
        {
            let token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            iota::transfer::public_transfer(token, INVESTOR2);
        };

        // 9. Revenue 2: NEW_OWNER deposits another 1M NANOS
        // Total Revenue: 2,000,000
        let revenue_amount_2 = 1_000_000;
        next_tx(&mut scenario, NEW_OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(revenue_amount_2, &mut scenario);

            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, payment, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 10. Claim 2: INVESTOR2 claims
        // Share: 100k / 1B = 0.01%
        // Total accrued for share = 2M * 0.01% = 200 NANOS
        // Already claimed on this token = 100 NANOS
        // Payout = 200 - 100 = 100 NANOS
        next_tx(&mut scenario, INVESTOR2);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);

            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, token);
        };

        // Verify Claim 2
        next_tx(&mut scenario, INVESTOR2);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(iota::coin::value(&cash) == 100, 2);
            test_scenario::return_to_sender(&scenario, cash);
        };

        // 11. Final Claim: NEW_OWNER claims the rest
        // Total Revenue: 2,000,000
        // Investor Share (0.01%): 200 NANOS
        // Owner Share (99.99%): 1,999,800 NANOS
        next_tx(&mut scenario, NEW_OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let mut bond = test_scenario::take_from_sender<OwnerBond>(&scenario);

            ltc1::claim_revenue_owner<IOTA>(&registry, &mut package, &mut bond, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // Verify Owner Amount
        next_tx(&mut scenario, NEW_OWNER);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(iota::coin::value(&cash) == 1_999_800, 3);
            test_scenario::return_to_sender(&scenario, cash);
        };

        test_scenario::end(scenario);
    }

    // Test: Supply Too Low
    // Scenario: Creator tries to issue a contract with only 100 tokens.
    // Limit: MIN_SUPPLY is 1,000,000,000.
    // Expected: Abort with E_SUPPLY_TOO_LOW.
    #[test]
    #[expected_failure(abort_code = ltc1::E_SUPPLY_TOO_LOW)]
    fun test_create_contract_supply_too_low() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                DOCUMENT_HASH,
                100, // TOO LOW (Min is 1B)
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        test_scenario::end(scenario);
    }

    // Test: Split Too High
    // Scenario: Creator tries to give investors 96% of the revenue.
    // Limit: MAX_INVESTOR_BPS is 9500 (95%).
    // Expected: Abort with E_INVALID_SPLIT.
    #[test]
    #[expected_failure(abort_code = ltc1::E_INVALID_SPLIT)]
    fun test_create_contract_split_too_high() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                960000, // TOO HIGH (Max is 950000)
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        test_scenario::end(scenario);
    }

    // Test: Double Claim
    // Scenario: Investor has 100k tokens. Revenue is 1M NANOS.
    // 1. Investor claims revenue (Expect 100 NANOS).
    // 2. Investor tries to claim AGAIN (Double Claim).
    // Expected: Function returns successfully but transfers NO coins (due == 0).
    // We verify this by ensuring no new coin object is sent to the investor.
    #[test]
    fun test_double_claim() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract & Get ID
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };

        next_tx(&mut scenario, ADMIN);
        let package_id = {
             let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let info = registry::get_hash_info(&registry, DOCUMENT_HASH);
            let contract_id_opt = registry::hash_contract_id(&info);
            let id = std::option::extract(&mut std::option::some(std::option::destroy_some(contract_id_opt)));
            test_scenario::return_shared(registry);
            id
        };

        // 2. Buy & Deposit Revenue
        let buy_amount = 100_000;
        let revenue_amount = 1_000_000;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(buy_amount * TOKEN_PRICE, &mut scenario);
            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(revenue_amount, &mut scenario);
            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, payment, ctx(&mut scenario));
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 3. Claim 1 (Should Succeed)
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);

            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, token);
        };

        // Check 1st Claim
        next_tx(&mut scenario, INVESTOR);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(iota::coin::value(&cash) == 100, 1);
            iota::transfer::public_transfer(cash, @0x0); // "Burn" it so next check is clean
        };

        // 4. Claim 2 (Double Claim - Should be No-Op)
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);

            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, token);
        };

        // Check 2nd Claim (Ensure NO new coin was sent)
        next_tx(&mut scenario, INVESTOR);
        {
            assert!(!test_scenario::has_most_recent_for_sender<Coin<IOTA>>(&scenario), 2);
        };

        test_scenario::end(scenario);
    }
}
