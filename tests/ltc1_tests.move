// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// Unit tests for LTC1
/// Test integration with registry and core ltc1 features (notarization-based API)

#[test_only]
module nplex::ltc1_tests {
    use nplex::ltc1::{Self, LTC1Package, LTC1Token, OwnerBond, LTC1Witness};
    use nplex::registry::{Self, NPLEXRegistry, NPLEXAdminCap};
    use iota::test_scenario::{Self, Scenario, next_tx, ctx};
    use iota::coin::{Self, Coin};
    use iota::iota::IOTA;
    use iota::clock::{Self};
    use std::string::{Self};
    use iota_notarization::notarization;
    use iota_notarization::dynamic_notarization;
    use iota_notarization::timelock;
    use iota_identity::controller;

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

    /// Stable mock ID for backing transfer/toggle authorizations in tests
    fun authorization_notarization_id(): ID { object::id_from_address(@0xAA1) }

    /// Identity IDs for test users (used as controller_of in DelegationTokens)
    fun owner_identity_id(): ID { object::id_from_address(@0xB1D) }
    fun investor_identity_id(): ID { object::id_from_address(@0xC1D) }
    fun investor2_identity_id(): ID { object::id_from_address(@0xE1D) }
    fun new_owner_identity_id(): ID { object::id_from_address(@0xD1D) }

    // ==================== Helpers ====================

    fun setup_registry(scenario: &mut Scenario) {
        // 1. Init Registry
        next_tx(scenario, ADMIN);
        registry::init_for_testing(ctx(scenario));

        // 2. Authorize LTC1 executor + whitelist test identities
        next_tx(scenario, ADMIN);
        let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
        let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);

        registry::add_executor<LTC1Witness>(&mut registry, &admin_cap);

        // Whitelist OWNER as Institution (role 1)
        registry::approve_identity(&mut registry, &admin_cap, owner_identity_id(), 1);
        // Whitelist INVESTOR as Investor (role 2)
        registry::approve_identity(&mut registry, &admin_cap, investor_identity_id(), 2);
        // Whitelist INVESTOR2 as Investor (role 2)
        registry::approve_identity(&mut registry, &admin_cap, investor2_identity_id(), 2);
        // Whitelist NEW_OWNER as Institution (role 1)
        registry::approve_identity(&mut registry, &admin_cap, new_owner_identity_id(), 1);

        test_scenario::return_shared(registry);
        test_scenario::return_to_sender(scenario, admin_cap);
    }

    fun mint_coins(amount: u64, scenario: &mut Scenario): Coin<IOTA> {
        coin::mint_for_testing<IOTA>(amount, ctx(scenario))
    }

    /// Helper: creates a real Notarization<u256> object, registers it in the registry,
    /// then calls the production create_contract.
    /// Flow: ADMIN tx (create notarization + register) → OWNER tx (create_contract)
    fun create_contract_with_notarization(scenario: &mut Scenario): ID {
        // Step 1: ADMIN creates notarization object and registers its real ID
        next_tx(scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);
            let clock = clock::create_for_testing(ctx(scenario));

            // Create a real Notarization<u256> object
            let state = notarization::new_state_from_generic<u256>(DOCUMENT_HASH, option::none());
            let notarization_obj = dynamic_notarization::new<u256>(
                state, option::none(), option::none(), timelock::none(), &clock, ctx(scenario)
            );

            // Register the real notarization ID
            let real_id = object::id(&notarization_obj);
            registry::register_notarization(
                &mut registry, &admin_cap, real_id, DOCUMENT_HASH, OWNER, &clock, ctx(scenario)
            );

            dynamic_notarization::transfer(notarization_obj, OWNER, &clock, ctx(scenario));

            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario, admin_cap);
        };

        // Step 2: OWNER uses the notarization to create the contract
        next_tx(scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let notarization_obj = test_scenario::take_from_sender<notarization::Notarization<u256>>(scenario);
            let clock = clock::create_for_testing(ctx(scenario));
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(scenario));

            ltc1::create_contract<IOTA>(
                &mut registry,
                string::utf8(b"LTC1 Package"),
                &notarization_obj,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &did_token,
                &clock,
                ctx(scenario)
            );

            controller::destroy_delegation_token_for_testing(did_token);

            notarization::destroy(notarization_obj, &clock);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };

        // Step 3: Retrieve package_id from the OwnerBond
        next_tx(scenario, OWNER);
        let package_id = {
            let bond = test_scenario::take_from_sender<OwnerBond>(scenario);
            let id = ltc1::bond_package_id(&bond);
            test_scenario::return_to_sender(scenario, bond);
            id
        };
        package_id
    }

    /// Helper: Admin authorizes + executes sales open for a package
    fun open_sales(scenario: &mut Scenario, package_id: ID) {
        // Admin authorizes
        next_tx(scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);
            registry::authorize_sales_toggle(&mut registry, &admin_cap, package_id, true, authorization_notarization_id());
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario, admin_cap);
        };
        // Execute toggle
        next_tx(scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(scenario, package_id);
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(scenario));
            ltc1::toggle_sales<IOTA>(&mut registry, &mut package, &did_token, ctx(scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };
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
        let package_id = create_contract_with_notarization(&mut scenario);

        // 1.6 Open Sales
        open_sales(&mut scenario, package_id);

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
            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));

            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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
            let did_token = controller::create_delegation_token_for_testing(investor2_identity_id(), ctx(&mut scenario));

            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount_2, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));

            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, payment, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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

            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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

            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));

            ltc1::claim_revenue_owner<IOTA>(&registry, &mut package, &mut bond, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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
        let package_id = create_contract_with_notarization(&mut scenario);

        // 1.6 Open Sales
        open_sales(&mut scenario, package_id);

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
            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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
    #[expected_failure(abort_code = registry::E_NOTARIZATION_NOT_APPROVED)]
    fun test_create_contract_not_registered_notarization() {
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

            // ONLY Authorize Witness (no notarization registered)
            registry::add_executor<LTC1Witness>(&mut registry, &admin_cap);
            // Whitelist OWNER identity for DID verification
            registry::approve_identity(&mut registry, &admin_cap, owner_identity_id(), 1);

            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // Try to create contract (Should Fail) - create notarization but don't register it
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            let state = notarization::new_state_from_generic<u256>(DOCUMENT_HASH, option::none());
            let notarization_obj = dynamic_notarization::new<u256>(
                state, option::none(), option::none(), timelock::none(), &clock, ctx(&mut scenario)
            );
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                string::utf8(b"LTC1 Package"),
                &notarization_obj,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &did_token,
                &clock,
                ctx(&mut scenario)
            );
            controller::destroy_delegation_token_for_testing(did_token);
            notarization::destroy(notarization_obj, &clock);
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
            let clock = clock::create_for_testing(ctx(&mut scenario));

            // Create real notarization object and register it, but DO NOT authorize witness
            let state = notarization::new_state_from_generic<u256>(DOCUMENT_HASH, option::none());
            let notarization_obj = dynamic_notarization::new<u256>(
                state, option::none(), option::none(), timelock::none(), &clock, ctx(&mut scenario)
            );
            let real_id = object::id(&notarization_obj);
            registry::register_notarization(&mut registry, &admin_cap, real_id, DOCUMENT_HASH, OWNER, &clock, ctx(&mut scenario));
            dynamic_notarization::transfer(notarization_obj, OWNER, &clock, ctx(&mut scenario));
            // Whitelist OWNER identity for DID verification
            registry::approve_identity(&mut registry, &admin_cap, owner_identity_id(), 1);

            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // Try to create contract (Should Fail - witness not authorized)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let notarization_obj = test_scenario::take_from_sender<notarization::Notarization<u256>>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                string::utf8(b"LTC1 Package"),
                &notarization_obj,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &did_token,
                &clock,
                ctx(&mut scenario)
            );
            controller::destroy_delegation_token_for_testing(did_token);
            notarization::destroy(notarization_obj, &clock);
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
        let package_id = create_contract_with_notarization(&mut scenario);

        // 3. Authorize Transfer (Admin)
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::authorize_transfer(
                &mut registry,
                &admin_cap,
                package_id,
                NEW_OWNER,
                authorization_notarization_id()
            );

            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 4. Transfer Bond (Owner)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let sender_did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            let new_owner_did_token = controller::create_delegation_token_for_testing(new_owner_identity_id(), ctx(&mut scenario));
            
            ltc1::transfer_bond(
                &mut registry,
                bond,
                NEW_OWNER,
                &sender_did_token,
                &new_owner_did_token,
                ctx(&mut scenario)
            );
            controller::destroy_delegation_token_for_testing(sender_did_token);
            controller::destroy_delegation_token_for_testing(new_owner_did_token);

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
        let package_id = create_contract_with_notarization(&mut scenario);

        // 1.6 Open Sales
        open_sales(&mut scenario, package_id);

        // 2. Buy Tokens (Investor) -> Funds the pool
        let buy_amount = 100_000;
        let cost = buy_amount * TOKEN_PRICE; 
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);
            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));

            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 3. Withdraw Funding (Owner)
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));

            ltc1::withdraw_funding<IOTA>(&registry, &mut package, &bond, cost, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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
        let package_id = create_contract_with_notarization(&mut scenario);

        // 1.6 Open Sales
        open_sales(&mut scenario, package_id);

        // 2. Funding: Investor buys 100k tokens
        // Cost: 100,000 * 1,000 = 100,000,000 NANOS (0.1 IOTA)
        let buy_amount = 100_000;
        let cost = buy_amount * TOKEN_PRICE; 
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);
            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));

            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 3. Withdrawal: Owner withdraws funding
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));

            ltc1::withdraw_funding<IOTA>(&registry, &mut package, &bond, cost, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            
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
            registry::authorize_transfer(&mut registry, &admin_cap, package_id, NEW_OWNER, authorization_notarization_id());
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 5. Handover: Transfer Bond (Owner -> NEW_OWNER)
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let sender_did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            let new_owner_did_token = controller::create_delegation_token_for_testing(new_owner_identity_id(), ctx(&mut scenario));
            ltc1::transfer_bond(&mut registry, bond, NEW_OWNER, &sender_did_token, &new_owner_did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(sender_did_token);
            controller::destroy_delegation_token_for_testing(new_owner_did_token);
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
            let did_token = controller::create_delegation_token_for_testing(new_owner_identity_id(), ctx(&mut scenario));

            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, payment, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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

            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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
            let did_token = controller::create_delegation_token_for_testing(new_owner_identity_id(), ctx(&mut scenario));

            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, payment, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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

            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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
            let did_token = controller::create_delegation_token_for_testing(new_owner_identity_id(), ctx(&mut scenario));

            ltc1::claim_revenue_owner<IOTA>(&registry, &mut package, &mut bond, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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
            let state = notarization::new_state_from_generic<u256>(DOCUMENT_HASH, option::none());
            let notarization_obj = dynamic_notarization::new<u256>(
                state, option::none(), option::none(), timelock::none(), &clock, ctx(&mut scenario)
            );
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                string::utf8(b"LTC1 Package"),
                &notarization_obj,
                100, // TOO LOW (Min is 1B)
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &did_token,
                &clock,
                ctx(&mut scenario)
            );
            controller::destroy_delegation_token_for_testing(did_token);
            notarization::destroy(notarization_obj, &clock);
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
            let state = notarization::new_state_from_generic<u256>(DOCUMENT_HASH, option::none());
            let notarization_obj = dynamic_notarization::new<u256>(
                state, option::none(), option::none(), timelock::none(), &clock, ctx(&mut scenario)
            );
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                string::utf8(b"LTC1 Package"),
                &notarization_obj,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                960000, // TOO HIGH (Max is 950000)
                string::utf8(b"ipfs://metadata"),
                &did_token,
                &clock,
                ctx(&mut scenario)
            );
            controller::destroy_delegation_token_for_testing(did_token);
            notarization::destroy(notarization_obj, &clock);
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
        let package_id = create_contract_with_notarization(&mut scenario);

        // 1.6 Open Sales
        open_sales(&mut scenario, package_id);

        // 2. Buy & Deposit Revenue
        let buy_amount = 100_000;
        let revenue_amount = 1_000_000;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(buy_amount * TOKEN_PRICE, &mut scenario);
            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(revenue_amount, &mut scenario);
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, payment, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
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

            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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

            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);

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
    #[test]
    fun test_update_authorized_creator() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // 1. Initial Setup: Create notarization, register with OWNER (A1)
        next_tx(&mut scenario, ADMIN);
        registry::init_for_testing(ctx(&mut scenario));
        
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            
            // Create real notarization object
            let state = notarization::new_state_from_generic<u256>(DOCUMENT_HASH, option::none());
            let notarization_obj = dynamic_notarization::new<u256>(
                state, option::none(), option::none(), timelock::none(), &clock, ctx(&mut scenario)
            );
            let real_id = object::id(&notarization_obj);
            
            registry::register_notarization(&mut registry, &admin_cap, real_id, DOCUMENT_HASH, OWNER, &clock, ctx(&mut scenario));
            registry::add_executor<LTC1Witness>(&mut registry, &admin_cap);
            // Whitelist identities for DID verification
            registry::approve_identity(&mut registry, &admin_cap, owner_identity_id(), 1);
            registry::approve_identity(&mut registry, &admin_cap, new_owner_identity_id(), 1);
            
            // 2. Update Authorized Creator to NEW_OWNER (A2)
            registry::update_authorized_creator(&mut registry, &admin_cap, real_id, NEW_OWNER);
            
            dynamic_notarization::transfer(notarization_obj, NEW_OWNER, &clock, ctx(&mut scenario));
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 3. T1: NEW_OWNER (A2) creates contract -> Success
        next_tx(&mut scenario, NEW_OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let notarization_obj = test_scenario::take_from_sender<notarization::Notarization<u256>>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            let did_token = controller::create_delegation_token_for_testing(new_owner_identity_id(), ctx(&mut scenario));
            
            ltc1::create_contract<IOTA>(
                &mut registry,
                string::utf8(b"LTC1 Package"),
                &notarization_obj,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &did_token,
                &clock,
                ctx(&mut scenario)
            );
            controller::destroy_delegation_token_for_testing(did_token);
            
            notarization::destroy(notarization_obj, &clock);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_UNAUTHORIZED_CREATOR)]
    fun test_update_authorized_creator_failure_old_owner() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // 1. Initial Setup: Create notarization, register with OWNER (A1)
        next_tx(&mut scenario, ADMIN);
        registry::init_for_testing(ctx(&mut scenario));
        
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            
            // Create real notarization object
            let state = notarization::new_state_from_generic<u256>(DOCUMENT_HASH, option::none());
            let notarization_obj = dynamic_notarization::new<u256>(
                state, option::none(), option::none(), timelock::none(), &clock, ctx(&mut scenario)
            );
            let real_id = object::id(&notarization_obj);
            
            registry::register_notarization(&mut registry, &admin_cap, real_id, DOCUMENT_HASH, OWNER, &clock, ctx(&mut scenario));
            registry::add_executor<LTC1Witness>(&mut registry, &admin_cap);
            // Whitelist identities for DID verification
            registry::approve_identity(&mut registry, &admin_cap, owner_identity_id(), 1);
            registry::approve_identity(&mut registry, &admin_cap, new_owner_identity_id(), 1);
            
            // Update Authorized Creator to NEW_OWNER (A2)
            registry::update_authorized_creator(&mut registry, &admin_cap, real_id, NEW_OWNER);
            
            dynamic_notarization::transfer(notarization_obj, OWNER, &clock, ctx(&mut scenario));
            
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 3. T2: OWNER (A1) tries to create contract -> Error
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let notarization_obj = test_scenario::take_from_sender<notarization::Notarization<u256>>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            
            ltc1::create_contract<IOTA>(
                &mut registry,
                string::utf8(b"LTC1 Package"),
                &notarization_obj,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &did_token,
                &clock,
                ctx(&mut scenario)
            );
            controller::destroy_delegation_token_for_testing(did_token);
            
            notarization::destroy(notarization_obj, &clock);
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        test_scenario::end(scenario);
    }

    // ==================== Sales Toggle Tests ====================

    // Test: Close Sales Blocks Buying
    // Scenario: Admin closes sales. Investor tries to buy tokens.
    // Expected: Abort with E_SALES_CLOSED.
    #[test]
    #[expected_failure(abort_code = ltc1::E_SALES_CLOSED)]
    fun test_close_sales_blocks_buying() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract
        let package_id = create_contract_with_notarization(&mut scenario);

        // 3. Admin authorizes close sales
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::authorize_sales_toggle(&mut registry, &admin_cap, package_id, false, authorization_notarization_id());
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 4. Execute toggle
        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            ltc1::toggle_sales<IOTA>(&mut registry, &mut package, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 5. Investor tries to buy (Should Fail)
        let buy_amount = 100_000;
        let cost = buy_amount * TOKEN_PRICE;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);
            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        test_scenario::end(scenario);
    }

    // Test: Reopen Sales Allows Buying
    // Scenario: Admin closes sales, then reopens them. Investor buys successfully.
    #[test]
    fun test_reopen_sales_allows_buying() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract
        let package_id = create_contract_with_notarization(&mut scenario);

        // 3. Admin closes sales
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::authorize_sales_toggle(&mut registry, &admin_cap, package_id, false, authorization_notarization_id());
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            ltc1::toggle_sales<IOTA>(&mut registry, &mut package, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 4. Admin reopens sales
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::authorize_sales_toggle(&mut registry, &admin_cap, package_id, true, authorization_notarization_id());
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            ltc1::toggle_sales<IOTA>(&mut registry, &mut package, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 5. Investor buys (Should Succeed)
        let buy_amount = 100_000;
        let cost = buy_amount * TOKEN_PRICE;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);
            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 6. Verify token received
        next_tx(&mut scenario, INVESTOR);
        {
            let token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            assert!(ltc1::balance(&token) == 100_000, 0);
            test_scenario::return_to_sender(&scenario, token);
        };

        test_scenario::end(scenario);
    }

    // Test: Close Sales Does NOT Block Revenue Claims
    // Scenario: Investor buys tokens, sales are closed, owner deposits revenue,
    // investor can still claim revenue.
    #[test]
    fun test_close_sales_does_not_block_claims() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        // 1. Create Contract
        let package_id = create_contract_with_notarization(&mut scenario);

        // 2.5 Open Sales first
        open_sales(&mut scenario, package_id);

        // 3. Investor buys tokens BEFORE close
        let buy_amount = 100_000;
        let cost = buy_amount * TOKEN_PRICE;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);
            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 4. Admin closes sales
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::authorize_sales_toggle(&mut registry, &admin_cap, package_id, false, authorization_notarization_id());
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            ltc1::toggle_sales<IOTA>(&mut registry, &mut package, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 5. Owner deposits revenue (should work even with sales closed)
        let revenue_amount = 1_000_000;
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(revenue_amount, &mut scenario);
            let did_token = controller::create_delegation_token_for_testing(owner_identity_id(), ctx(&mut scenario));
            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, payment, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 6. Investor claims revenue (should work even with sales closed)
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            let did_token = controller::create_delegation_token_for_testing(investor_identity_id(), ctx(&mut scenario));
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, &did_token, ctx(&mut scenario));
            controller::destroy_delegation_token_for_testing(did_token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, token);
        };

        // 7. Verify Investor received revenue (100 NANOS)
        next_tx(&mut scenario, INVESTOR);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(iota::coin::value(&cash) == 100, 1);
            test_scenario::return_to_sender(&scenario, cash);
        };

        test_scenario::end(scenario);
    }
}
