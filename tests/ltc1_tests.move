// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// Unit tests for LTC1
/// Test integration with registry and core ltc1 features

#[test_only]
module nplex::ltc1_tests {
    use nplex::ltc1::{Self, LTC1Package, OwnerBond, LTC1Witness};
    use nplex::registry::{Self, NPLEXRegistry, NPLEXAdminCap};
    use iota::test_scenario::{Self, Scenario, next_tx, ctx};
    use iota::coin::{Self, Coin, TreasuryCap};
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

    // ==================== Test Investor Token ====================
    
    /// Test-only investor token type.
    /// In production, each NPL package creator deploys their own OTW module.
    public struct TEST_TOKEN has drop {}

    // ==================== Helpers ====================

    fun setup_registry(scenario: &mut Scenario) {
        // 1. Init Registry
        next_tx(scenario, ADMIN);
        registry::init_for_testing(ctx(scenario));

        // 2. Register Hash & Authorize LTC1
        next_tx(scenario, ADMIN);
        let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
        let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);
        let clock = clock::create_for_testing(ctx(scenario));

        registry::register_hash(&mut registry, &admin_cap, DOCUMENT_HASH, OWNER, &clock, ctx(scenario));
        registry::add_executor<LTC1Witness>(&mut registry, &admin_cap);

        clock::destroy_for_testing(clock);
        test_scenario::return_shared(registry);
        test_scenario::return_to_sender(scenario, admin_cap);
    }

    fun mint_coins(amount: u64, scenario: &mut Scenario): Coin<IOTA> {
        coin::mint_for_testing<IOTA>(amount, ctx(scenario))
    }

    fun create_test_treasury(scenario: &mut Scenario): TreasuryCap<TEST_TOKEN> {
        coin::create_treasury_cap_for_testing<TEST_TOKEN>(ctx(scenario))
    }

    /// Helper: Creates contract and returns the package_id
    fun create_default_contract(scenario: &mut Scenario): ID {
        next_tx(scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let clock = clock::create_for_testing(ctx(scenario));
            let treasury_cap = create_test_treasury(scenario);
            ltc1::create_contract<IOTA, TEST_TOKEN>(
                &mut registry,
                treasury_cap,
                string::utf8(b"LTC1 Package"),
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(scenario)
            );
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };

        // Get Package ID from Registry
        next_tx(scenario, ADMIN);
        let package_id = {
            let registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let info = registry::get_hash_info(&registry, DOCUMENT_HASH);
            let contract_id_opt = registry::hash_contract_id(&info);
            let id = std::option::extract(&mut std::option::some(std::option::destroy_some(contract_id_opt)));
            test_scenario::return_shared(registry);
            id
        };
        package_id
    }

    // ==================== Tests ====================

    // Test end to end flow with redeem model using Coin<T>
    // Scenario: An LTC1 is issued with 1B tokens and price of 1,000 NANOS.
    // 100k tokens are sold to investor 1, 200k tokens are sold to investor 2.
    // Owner deposits 1M NANOS into revenue pool.
    // Revenue split at deposit: owner share = (1B - 300k)/1B * 1M = 999,700
    //                            investor share = 300k/1B * 1M = 300
    // Investor 1 redeems 100k tokens → gets 100k/300k * 300 = 100 NANOS
    // Investor 2 redeems 200k tokens → gets 200k/200k * 200 = 200 NANOS (remaining investor pool)
    // Owner claims → gets 999,700 NANOS
    #[test]
    fun test_end_to_end_flow() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_default_contract(&mut scenario);

        // 1. Buy Tokens (Investor 1: 100k)
        let buy_amount = 100_000;
        let cost = buy_amount * TOKEN_PRICE;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);

            ltc1::buy_token<IOTA, TEST_TOKEN>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 2. Buy Tokens (Investor 2: 200k)
        let buy_amount_2 = 200_000;
        let cost_2 = buy_amount_2 * TOKEN_PRICE;
        
        next_tx(&mut scenario, INVESTOR2);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let payment = mint_coins(cost_2, &mut scenario);

            ltc1::buy_token<IOTA, TEST_TOKEN>(&registry, &mut package, payment, buy_amount_2, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // Assert investor 1 has 100,000 tokens (as Coin<TEST_TOKEN>)
        next_tx(&mut scenario, INVESTOR);
        {
            let token = test_scenario::take_from_sender<Coin<TEST_TOKEN>>(&scenario);
            assert!(coin::value(&token) == 100_000, 0);
            test_scenario::return_to_sender(&scenario, token);
        };

        // 3. Deposit Revenue (Owner): 1M NANOS
        let revenue_amount = 1_000_000;
        
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(revenue_amount, &mut scenario);

            ltc1::deposit_revenue<IOTA, TEST_TOKEN>(&registry, &mut package, &bond, payment, ctx(&mut scenario));

            // Verify owner_claimable is set correctly
            assert!(ltc1::owner_claimable(&package) == 999_700, 10);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 4. Redeem (Investor 1): burn 100k tokens via Coin<TEST_TOKEN>
        // investor_pool = 1M - 999,700 = 300
        // payout = 100k/300k * 300 = 100
        next_tx(&mut scenario, INVESTOR);
        {
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let token = test_scenario::take_from_sender<Coin<TEST_TOKEN>>(&scenario);

            ltc1::redeem<IOTA, TEST_TOKEN>(&mut package, token, ctx(&mut scenario));

            test_scenario::return_shared(package);
        };

        // Verify Investor 1 payout (100 NANOS as Coin<IOTA>)
        next_tx(&mut scenario, INVESTOR);
        {
            let revenue = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(coin::value(&revenue) == 100, 2);
            test_scenario::return_to_sender(&scenario, revenue);
        };

        // 5. Redeem (Investor 2): burn 200k tokens
        next_tx(&mut scenario, INVESTOR2);
        {
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let token = test_scenario::take_from_sender<Coin<TEST_TOKEN>>(&scenario);

            ltc1::redeem<IOTA, TEST_TOKEN>(&mut package, token, ctx(&mut scenario));

            test_scenario::return_shared(package);
        };

        // Verify Investor 2 payout (200 NANOS)
        next_tx(&mut scenario, INVESTOR2);
        {
            let revenue = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(coin::value(&revenue) == 200, 3);
            test_scenario::return_to_sender(&scenario, revenue);
        };

        // 6. Claim Revenue (Owner): 999,700 NANOS
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);

            ltc1::claim_revenue_owner<IOTA, TEST_TOKEN>(&registry, &mut package, &bond, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // Verify Owner Revenue (999,700 NANOS)
        next_tx(&mut scenario, OWNER);
        {
            let revenue = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(coin::value(&revenue) == 999_700, 4);
            test_scenario::return_to_sender(&scenario, revenue);
        };

        test_scenario::end(scenario);
    }

    // Test supply split enforcement
    #[test]
    #[expected_failure(abort_code = ltc1::E_INSUFFICIENT_SUPPLY)]
    fun test_supply_split_enforcement() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_default_contract(&mut scenario);

        let buy_amount = 500_000_001;
        let cost = buy_amount * TOKEN_PRICE;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);

            ltc1::buy_token<IOTA, TEST_TOKEN>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        test_scenario::end(scenario);
    }

    // Test contract creation with unregistered hash
    #[test]
    #[expected_failure(abort_code = registry::E_HASH_NOT_APPROVED)]
    fun test_create_contract_not_registered_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        next_tx(&mut scenario, ADMIN);
        registry::init_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::add_executor<LTC1Witness>(&mut registry, &admin_cap);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            let treasury_cap = create_test_treasury(&mut scenario);
            ltc1::create_contract<IOTA, TEST_TOKEN>(
                &mut registry,
                treasury_cap,
                string::utf8(b"LTC1 Package"),
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
    #[test]
    #[expected_failure(abort_code = registry::E_UNAUTHORIZED_EXECUTOR)]
    fun test_create_contract_unauthorized_witness() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        next_tx(&mut scenario, ADMIN);
        registry::init_for_testing(ctx(&mut scenario));

        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            registry::register_hash(&mut registry, &admin_cap, DOCUMENT_HASH, OWNER, &clock, ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            let treasury_cap = create_test_treasury(&mut scenario);
            ltc1::create_contract<IOTA, TEST_TOKEN>(
                &mut registry,
                treasury_cap,
                string::utf8(b"LTC1 Package"),
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
    #[test]
    fun test_owner_bond_transfer() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_default_contract(&mut scenario);

        // 1. Authorize Transfer (Admin)
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

        // 2. Transfer Bond (Owner)
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

        // 3. Verify New Owner has Bond
        next_tx(&mut scenario, NEW_OWNER);
        {
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            assert!(object::id(&bond) != object::id_from_address(@0x0), 0);
            test_scenario::return_to_sender(&scenario, bond);
        };

        test_scenario::end(scenario);
    }

    // Test withdraw funding
    #[test]
    fun test_withdraw_funding() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_default_contract(&mut scenario);

        let buy_amount = 100_000;
        let cost = buy_amount * TOKEN_PRICE; 
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);

            ltc1::buy_token<IOTA, TEST_TOKEN>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);

            ltc1::withdraw_funding<IOTA, TEST_TOKEN>(&registry, &mut package, &bond, cost, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };
        
        next_tx(&mut scenario, OWNER);
        {
            let withdrawn_coin = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(coin::value(&withdrawn_coin) == cost, 0);
            test_scenario::return_to_sender(&scenario, withdrawn_coin);
        };

        test_scenario::end(scenario);
    }

    // Test Complex Lifecycle Flow with redeem model
    #[test]
    fun test_complex_lifecycle_flow() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_default_contract(&mut scenario);

        // 1. Funding: Investor buys 100k tokens
        let buy_amount = 100_000;
        let cost = buy_amount * TOKEN_PRICE; 
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let payment = mint_coins(cost, &mut scenario);

            ltc1::buy_token<IOTA, TEST_TOKEN>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 2. Withdrawal: Owner withdraws funding
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);

            ltc1::withdraw_funding<IOTA, TEST_TOKEN>(&registry, &mut package, &bond, cost, ctx(&mut scenario));
            
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        next_tx(&mut scenario, OWNER);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(coin::value(&cash) == cost, 0);
            test_scenario::return_to_sender(&scenario, cash);
        };

        // 3. Handover: Authorize & Transfer Bond
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::authorize_transfer(&mut registry, &admin_cap, package_id, NEW_OWNER);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            ltc1::transfer_bond(&mut registry, bond, NEW_OWNER, ctx(&mut scenario));
            test_scenario::return_shared(registry);
        };

        // 4. Revenue 1: NEW_OWNER deposits 1M NANOS
        // Split: owner_share = (1B - 100k)/1B * 1M = 999,900; investor = 100
        let revenue_amount_1 = 1_000_000;
        next_tx(&mut scenario, NEW_OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(revenue_amount_1, &mut scenario);

            ltc1::deposit_revenue<IOTA, TEST_TOKEN>(&registry, &mut package, &bond, payment, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 5. Redeem: INVESTOR redeems all 100k tokens
        // investor_pool = 1M - 999,900 = 100
        // payout = 100k/100k * 100 = 100
        next_tx(&mut scenario, INVESTOR);
        {
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let token = test_scenario::take_from_sender<Coin<TEST_TOKEN>>(&scenario);

            ltc1::redeem<IOTA, TEST_TOKEN>(&mut package, token, ctx(&mut scenario));

            test_scenario::return_shared(package);
        };

        next_tx(&mut scenario, INVESTOR);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(coin::value(&cash) == 100, 1);
            test_scenario::return_to_sender(&scenario, cash);
        };

        // 6. Revenue 2: NEW_OWNER deposits another 1M NANOS
        // After investor redeemed: total_supply = 999,999,900, tokens_sold = 0
        // owner_share = (999,999,900 - 0)/999,999,900 * 1M = 1,000,000
        let revenue_amount_2 = 1_000_000;
        next_tx(&mut scenario, NEW_OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(revenue_amount_2, &mut scenario);

            ltc1::deposit_revenue<IOTA, TEST_TOKEN>(&registry, &mut package, &bond, payment, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 7. Owner Claims: 999,900 + 1,000,000 = 1,999,900
        next_tx(&mut scenario, NEW_OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);

            ltc1::claim_revenue_owner<IOTA, TEST_TOKEN>(&registry, &mut package, &bond, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        next_tx(&mut scenario, NEW_OWNER);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(coin::value(&cash) == 1_999_900, 3);
            test_scenario::return_to_sender(&scenario, cash);
        };

        test_scenario::end(scenario);
    }

    // Test: Supply Too Low
    #[test]
    #[expected_failure(abort_code = ltc1::E_SUPPLY_TOO_LOW)]
    fun test_create_contract_supply_too_low() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            let treasury_cap = create_test_treasury(&mut scenario);
            ltc1::create_contract<IOTA, TEST_TOKEN>(
                &mut registry,
                treasury_cap,
                string::utf8(b"LTC1 Package"),
                DOCUMENT_HASH,
                100, // TOO LOW
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
    #[test]
    #[expected_failure(abort_code = ltc1::E_INVALID_SPLIT)]
    fun test_create_contract_split_too_high() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);

        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            let treasury_cap = create_test_treasury(&mut scenario);
            ltc1::create_contract<IOTA, TEST_TOKEN>(
                &mut registry,
                treasury_cap,
                string::utf8(b"LTC1 Package"),
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                960000, // TOO HIGH
                string::utf8(b"ipfs://metadata"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };
        test_scenario::end(scenario);
    }

    // Test: Owner double claim is impossible
    #[test]
    fun test_owner_double_claim() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_default_contract(&mut scenario);

        // 1. Buy & Deposit Revenue
        let buy_amount = 100_000;
        
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let payment = mint_coins(buy_amount * TOKEN_PRICE, &mut scenario);
            ltc1::buy_token<IOTA, TEST_TOKEN>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(1_000_000, &mut scenario);
            ltc1::deposit_revenue<IOTA, TEST_TOKEN>(&registry, &mut package, &bond, payment, ctx(&mut scenario));
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 2. Owner Claim 1
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);

            ltc1::claim_revenue_owner<IOTA, TEST_TOKEN>(&registry, &mut package, &bond, ctx(&mut scenario));
            assert!(ltc1::owner_claimable(&package) == 0, 1);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // Verify claim 1 payout
        next_tx(&mut scenario, OWNER);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(coin::value(&cash) == 999_900, 2);
            iota::transfer::public_transfer(cash, @0x0);
        };

        // 3. Owner Claim 2 (Double Claim - Should be No-Op)
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);

            ltc1::claim_revenue_owner<IOTA, TEST_TOKEN>(&registry, &mut package, &bond, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // Verify NO coin was sent on second claim
        next_tx(&mut scenario, OWNER);
        {
            assert!(!test_scenario::has_most_recent_for_sender<Coin<IOTA>>(&scenario), 3);
        };

        test_scenario::end(scenario);
    }

    // Test: Partial Redeem using Coin<T>
    #[test]
    fun test_redeem_partial() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_default_contract(&mut scenario);

        // 1. Buy 100k tokens
        let buy_amount = 100_000;
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let payment = mint_coins(buy_amount * TOKEN_PRICE, &mut scenario);
            ltc1::buy_token<IOTA, TEST_TOKEN>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 2. Deposit 1M NANOS
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            let payment = mint_coins(1_000_000, &mut scenario);
            ltc1::deposit_revenue<IOTA, TEST_TOKEN>(&registry, &mut package, &bond, payment, ctx(&mut scenario));
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 3. Redeem HALF (50k) — partial redemption
        // investor_pool = 1M - 999,900 = 100
        // payout = 50k/100k * 100 = 50
        next_tx(&mut scenario, INVESTOR);
        {
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let mut token = test_scenario::take_from_sender<Coin<TEST_TOKEN>>(&scenario);

            // Partial: split coin first, then redeem the split portion
            let to_redeem = coin::split(&mut token, 50_000, ctx(&mut scenario));
            ltc1::redeem<IOTA, TEST_TOKEN>(&mut package, to_redeem, ctx(&mut scenario));

            // Return remaining tokens to sender
            iota::transfer::public_transfer(token, INVESTOR);
            test_scenario::return_shared(package);
        };

        // Verify first payout (50 NANOS) + remaining tokens (50k)
        next_tx(&mut scenario, INVESTOR);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(coin::value(&cash) == 50, 1);
            test_scenario::return_to_sender(&scenario, cash);

            let remaining_tokens = test_scenario::take_from_sender<Coin<TEST_TOKEN>>(&scenario);
            assert!(coin::value(&remaining_tokens) == 50_000, 2);
            test_scenario::return_to_sender(&scenario, remaining_tokens);
        };

        // 4. Redeem remaining 50k
        // investor_pool = 100 - 50 = 50 (after first redeem)
        // tokens_sold = 50k
        // payout = 50k/50k * 50 = 50
        next_tx(&mut scenario, INVESTOR);
        {
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let token = test_scenario::take_from_sender<Coin<TEST_TOKEN>>(&scenario);

            ltc1::redeem<IOTA, TEST_TOKEN>(&mut package, token, ctx(&mut scenario));

            test_scenario::return_shared(package);
        };

        // Verify second payout (50 NANOS)
        next_tx(&mut scenario, INVESTOR);
        {
            let cash = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(coin::value(&cash) == 50, 3);
            test_scenario::return_to_sender(&scenario, cash);
        };

        test_scenario::end(scenario);
    }

    // Test: Sales closed blocks buy
    #[test]
    #[expected_failure(abort_code = ltc1::E_SALES_CLOSED)]
    fun test_sales_closed_blocks_buy() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_default_contract(&mut scenario);

        // 1. Close Sales (Admin authorizes, then ltc1 consumes ticket)
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::authorize_sales_toggle(&mut registry, &admin_cap, package_id, false);

            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            
            ltc1::toggle_sales<IOTA, TEST_TOKEN>(&mut registry, &mut package);
            assert!(!ltc1::is_sales_open(&package), 0);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 2. Try to Buy (Should Fail)
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let payment = mint_coins(100_000 * TOKEN_PRICE, &mut scenario);

            ltc1::buy_token<IOTA, TEST_TOKEN>(&registry, &mut package, payment, 100_000, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        test_scenario::end(scenario);
    }

    // Test: Set token price
    #[test]
    fun test_set_token_price() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_default_contract(&mut scenario);

        // 1. Close sales (Admin authorizes + consume)
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::authorize_sales_toggle(&mut registry, &admin_cap, package_id, false);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            ltc1::toggle_sales<IOTA, TEST_TOKEN>(&mut registry, &mut package);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 2. Set new price
        let new_price = 2_000;
        next_tx(&mut scenario, OWNER);
        {
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            ltc1::set_token_price<IOTA, TEST_TOKEN>(&mut package, &bond, new_price);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        // 3. Reopen sales (Admin authorizes + consume)
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::authorize_sales_toggle(&mut registry, &admin_cap, package_id, true);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            ltc1::toggle_sales<IOTA, TEST_TOKEN>(&mut registry, &mut package);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 4. Buy at new price
        let buy_amount = 100_000;
        let new_cost = buy_amount * new_price;
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let payment = mint_coins(new_cost, &mut scenario);

            ltc1::buy_token<IOTA, TEST_TOKEN>(&registry, &mut package, payment, buy_amount, ctx(&mut scenario));

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        next_tx(&mut scenario, INVESTOR);
        {
            let token = test_scenario::take_from_sender<Coin<TEST_TOKEN>>(&scenario);
            assert!(coin::value(&token) == 100_000, 0);
            test_scenario::return_to_sender(&scenario, token);
        };

        test_scenario::end(scenario);
    }

    // Test: Cannot set price while sales are open
    #[test]
    #[expected_failure(abort_code = ltc1::E_SALES_OPEN)]
    fun test_set_token_price_fails_when_sales_open() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_default_contract(&mut scenario);

        next_tx(&mut scenario, OWNER);
        {
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA, TEST_TOKEN>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<OwnerBond>(&scenario);
            ltc1::set_token_price<IOTA, TEST_TOKEN>(&mut package, &bond, 2_000);
            test_scenario::return_shared(package);
            test_scenario::return_to_sender(&scenario, bond);
        };

        test_scenario::end(scenario);
    }

    // Test: update_authorized_creator
    #[test]
    fun test_update_authorized_creator() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        next_tx(&mut scenario, ADMIN);
        registry::init_for_testing(ctx(&mut scenario));
        
        next_tx(&mut scenario, ADMIN);
        let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
        let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        registry::register_hash(&mut registry, &admin_cap, DOCUMENT_HASH, OWNER, &clock, ctx(&mut scenario));
        registry::add_executor<LTC1Witness>(&mut registry, &admin_cap);
        
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(registry);
        test_scenario::return_to_sender(&scenario, admin_cap);

        // Update Authorized Creator to NEW_OWNER
        next_tx(&mut scenario, ADMIN);
        let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
        let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
        registry::update_authorized_creator(&mut registry, &admin_cap, DOCUMENT_HASH, NEW_OWNER);
        test_scenario::return_shared(registry);
        test_scenario::return_to_sender(&scenario, admin_cap);

        // NEW_OWNER creates contract -> Success
        next_tx(&mut scenario, NEW_OWNER);
        let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        let treasury_cap = create_test_treasury(&mut scenario);
        
        ltc1::create_contract<IOTA, TEST_TOKEN>(
            &mut registry,
            treasury_cap,
            string::utf8(b"LTC1 Package"),
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
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_UNAUTHORIZED_CREATOR)]
    fun test_update_authorized_creator_failure_old_owner() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        next_tx(&mut scenario, ADMIN);
        registry::init_for_testing(ctx(&mut scenario));
        
        next_tx(&mut scenario, ADMIN);
        let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
        let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        
        registry::register_hash(&mut registry, &admin_cap, DOCUMENT_HASH, OWNER, &clock, ctx(&mut scenario));
        registry::add_executor<LTC1Witness>(&mut registry, &admin_cap);
        
        clock::destroy_for_testing(clock);
        test_scenario::return_shared(registry);
        test_scenario::return_to_sender(&scenario, admin_cap);

        // Update Authorized Creator to NEW_OWNER
        next_tx(&mut scenario, ADMIN);
        let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
        let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
        registry::update_authorized_creator(&mut registry, &admin_cap, DOCUMENT_HASH, NEW_OWNER);
        test_scenario::return_shared(registry);
        test_scenario::return_to_sender(&scenario, admin_cap);

        // OWNER (old) tries to create contract -> Error
        next_tx(&mut scenario, OWNER);
        let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
        let clock = clock::create_for_testing(ctx(&mut scenario));
        let treasury_cap = create_test_treasury(&mut scenario);
        
        ltc1::create_contract<IOTA, TEST_TOKEN>(
            &mut registry,
            treasury_cap,
            string::utf8(b"LTC1 Package"),
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
        test_scenario::end(scenario);
    }
}
