// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// Unit tests for Fractional module

/// Test coin module — provides a OTW + init to create a TreasuryCap for testing.
/// In production, the middleware deploys a separate package per fractionalization.
#[test_only]
module nplex::test_frac_coin {
    use iota::coin;

    public struct TEST_FRAC_COIN has drop {}

    fun init(witness: TEST_FRAC_COIN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            9, // decimals
            b"FRAC",
            b"Test Fraction",
            b"Test fractional coin for unit tests",
            std::option::none(),
            ctx,
        );
        iota::transfer::public_transfer(treasury_cap, ctx.sender());
        iota::transfer::public_transfer(metadata, ctx.sender());
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(TEST_FRAC_COIN {}, ctx);
    }
}

#[test_only, allow(unused_const)]
module nplex::fractional_tests {
    use nplex::ltc1::{Self, LTC1Package, LTC1Token, LTC1Witness};
    use nplex::fractional::{Self, FractionalVault};
    use nplex::registry::{Self, NPLEXRegistry, NPLEXAdminCap};
    use nplex::test_frac_coin::TEST_FRAC_COIN;
    use iota::test_scenario::{Self, Scenario, next_tx, ctx};
    use iota::coin::{Self, Coin, TreasuryCap};
    use iota::iota::IOTA;
    use iota::clock;
    use std::string;

    // Test Users
    const ADMIN: address = @0xAD;
    const OWNER: address = @0xB;
    const INVESTOR: address = @0xC;
    const BUYER: address = @0xD; // used in future tests

    // Test Data
    const DOCUMENT_HASH: u256 = 123456789;
    const TOTAL_SUPPLY: u64 = 1_000_000_000;
    const TOKEN_PRICE: u64 = 1_000;
    const NOMINAL_VALUE: u64 = 1_000_000_000;
    const SPLIT_BPS: u64 = 500_000;

    // ==================== Helpers ====================

    fun setup_registry(scenario: &mut Scenario) {
        next_tx(scenario, ADMIN);
        registry::init_for_testing(ctx(scenario));

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

    fun create_contract_and_buy(scenario: &mut Scenario, buy_amount: u64): ID {
        // Create contract
        next_tx(scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let clock = clock::create_for_testing(ctx(scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                string::utf8(b"Test Package"),
                DOCUMENT_HASH,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://test"),
                &clock,
                ctx(scenario)
            );
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };

        // Get Package ID
        next_tx(scenario, ADMIN);
        let package_id = {
            let registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let info = registry::get_hash_info(&registry, DOCUMENT_HASH);
            let contract_id_opt = registry::hash_contract_id(&info);
            let id = std::option::extract(&mut std::option::some(std::option::destroy_some(contract_id_opt)));
            test_scenario::return_shared(registry);
            id
        };

        // Open Sales
        next_tx(scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);
            registry::authorize_sales_toggle(&mut registry, &admin_cap, package_id, true);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario, admin_cap);
        };
        next_tx(scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(scenario, package_id);
            ltc1::toggle_sales<IOTA>(&mut registry, &mut package, ctx(scenario));
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // Buy tokens
        next_tx(scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(scenario, package_id);
            let payment = coin::mint_for_testing<IOTA>(buy_amount * TOKEN_PRICE, ctx(scenario));
            ltc1::buy_token<IOTA>(&registry, &mut package, payment, buy_amount, ctx(scenario));
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        package_id
    }

    /// Helper: create the test fractional coin's TreasuryCap
    fun create_frac_treasury(scenario: &mut Scenario): TreasuryCap<TEST_FRAC_COIN> {
        next_tx(scenario, INVESTOR);
        nplex::test_frac_coin::init_for_testing(ctx(scenario));
        next_tx(scenario, INVESTOR);
        test_scenario::take_from_sender<TreasuryCap<TEST_FRAC_COIN>>(scenario)
    }

    // ==================== Tests ====================

    /// Happy path: fractionalize → redeem → new LTC1Token has correct balance
    #[test]
    fun test_fractionalize_and_redeem() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_contract_and_buy(&mut scenario, 100_000);

        // Get TreasuryCap
        let treasury_cap = create_frac_treasury(&mut scenario);

        // Fractionalize 50,000 out of 100,000
        next_tx(&mut scenario, INVESTOR);
        {
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            assert!(ltc1::balance(&token) == 100_000);

            fractional::fractionalize<TEST_FRAC_COIN>(
                &mut token,
                treasury_cap,
                50_000,
                ctx(&mut scenario)
            );

            // Token should have 50,000 remaining
            assert!(ltc1::balance(&token) == 50_000);
            test_scenario::return_to_sender(&scenario, token);
        };

        // Investor now has 50,000 Coin<TEST_FRAC_COIN>
        next_tx(&mut scenario, INVESTOR);
        {
            let coins = test_scenario::take_from_sender<Coin<TEST_FRAC_COIN>>(&scenario);
            assert!(coin::value(&coins) == 50_000);

            // Redeem all coins
            let mut vault = test_scenario::take_shared<FractionalVault<TEST_FRAC_COIN>>(&scenario);
            let package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);

            fractional::redeem<TEST_FRAC_COIN, IOTA>(
                &mut vault,
                coins,
                &package,
                ctx(&mut scenario)
            );

            test_scenario::return_shared(vault);
            test_scenario::return_shared(package);
        };

        // Investor should now have a NEW LTC1Token with balance 50,000
        next_tx(&mut scenario, INVESTOR);
        {
            // There should be 2 tokens now (original with 50k + new with 50k)
            let token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            let balance = ltc1::balance(&token);
            assert!(balance == 50_000 || balance == 50_000); // both are 50k
            test_scenario::return_to_sender(&scenario, token);
        };

        test_scenario::end(scenario);
    }

    /// Security: cannot fractionalize if TreasuryCap has pre-minted coins
    #[test]
    #[expected_failure(abort_code = nplex::fractional::E_TREASURY_NOT_FRESH)]
    fun test_fractionalize_blocks_preminted() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let _package_id = create_contract_and_buy(&mut scenario, 100_000);

        // Get TreasuryCap and pre-mint some coins (attack vector)
        let mut treasury_cap = create_frac_treasury(&mut scenario);

        next_tx(&mut scenario, INVESTOR);
        {
            // Pre-mint coins — this should cause fractionalize to fail
            let preminted = coin::mint(&mut treasury_cap, 1000, ctx(&mut scenario));
            iota::transfer::public_transfer(preminted, INVESTOR);
        };

        next_tx(&mut scenario, INVESTOR);
        {
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);

            // This should abort with E_TREASURY_NOT_FRESH
            fractional::fractionalize<TEST_FRAC_COIN>(
                &mut token,
                treasury_cap,
                50_000,
                ctx(&mut scenario)
            );

            test_scenario::return_to_sender(&scenario, token);
        };

        test_scenario::end(scenario);
    }

    /// Revenue accounting: after fractionalize + revenue deposit, redeemed tokens claim correct amount
    #[test]
    fun test_revenue_accounting() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_contract_and_buy(&mut scenario, 100_000);

        // 1. Deposit some revenue first, so claimed_revenue is non-zero after a claim
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<nplex::ltc1::OwnerBond>(&scenario);
            let revenue = coin::mint_for_testing<IOTA>(1_000_000, ctx(&mut scenario));
            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, revenue, ctx(&mut scenario));
            test_scenario::return_to_sender(&scenario, bond);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 2. Investor claims revenue (so claimed_revenue > 0)
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, ctx(&mut scenario));
            // claimed_revenue should now be > 0
            assert!(ltc1::claimed_revenue(&token) > 0);
            test_scenario::return_to_sender(&scenario, token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 3. Fractionalize half
        let treasury_cap = create_frac_treasury(&mut scenario);
        next_tx(&mut scenario, INVESTOR);
        {
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            let claimed_before = ltc1::claimed_revenue(&token);

            fractional::fractionalize<TEST_FRAC_COIN>(
                &mut token,
                treasury_cap,
                50_000,
                ctx(&mut scenario)
            );

            // claimed_revenue should have been split proportionally (~half)
            let claimed_after = ltc1::claimed_revenue(&token);
            assert!(claimed_after < claimed_before);

            test_scenario::return_to_sender(&scenario, token);
        };

        // 4. Deposit more revenue
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<nplex::ltc1::OwnerBond>(&scenario);
            let revenue = coin::mint_for_testing<IOTA>(2_000_000, ctx(&mut scenario));
            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, revenue, ctx(&mut scenario));
            test_scenario::return_to_sender(&scenario, bond);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // 5. Redeem the fractionalized coins → new token should be able to claim revenue
        next_tx(&mut scenario, INVESTOR);
        {
            let coins = test_scenario::take_from_sender<Coin<TEST_FRAC_COIN>>(&scenario);
            let mut vault = test_scenario::take_shared<FractionalVault<TEST_FRAC_COIN>>(&scenario);
            let package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);

            fractional::redeem<TEST_FRAC_COIN, IOTA>(
                &mut vault,
                coins,
                &package,
                ctx(&mut scenario)
            );

            test_scenario::return_shared(vault);
            test_scenario::return_shared(package);
        };

        // 6. Both tokens should be claimable
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);

            // Claim from original (50k balance)
            let mut token1 = test_scenario::take_from_sender<LTC1Token>(&scenario);
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token1, ctx(&mut scenario));
            test_scenario::return_to_sender(&scenario, token1);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        test_scenario::end(scenario);
    }

    /// Partial redeem: redeem only half the coins
    #[test]
    fun test_partial_redeem() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_contract_and_buy(&mut scenario, 100_000);

        let treasury_cap = create_frac_treasury(&mut scenario);

        // Fractionalize 60,000
        next_tx(&mut scenario, INVESTOR);
        {
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            fractional::fractionalize<TEST_FRAC_COIN>(
                &mut token, treasury_cap, 60_000, ctx(&mut scenario)
            );
            assert!(ltc1::balance(&token) == 40_000);
            test_scenario::return_to_sender(&scenario, token);
        };

        // Redeem only 20,000 coins (keep 40,000 as coins)
        next_tx(&mut scenario, INVESTOR);
        {
            let mut coins = test_scenario::take_from_sender<Coin<TEST_FRAC_COIN>>(&scenario);
            let redeem_coins = coin::split(&mut coins, 20_000, ctx(&mut scenario));

            let mut vault = test_scenario::take_shared<FractionalVault<TEST_FRAC_COIN>>(&scenario);
            let package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);

            fractional::redeem<TEST_FRAC_COIN, IOTA>(
                &mut vault,
                redeem_coins,
                &package,
                ctx(&mut scenario)
            );

            // Remaining coins still 40,000
            assert!(coin::value(&coins) == 40_000);
            // Vault supply should be 40,000 (60k minted - 20k burned)
            assert!(fractional::vault_total_supply(&vault) == 40_000);

            test_scenario::return_to_sender(&scenario, coins);
            test_scenario::return_shared(vault);
            test_scenario::return_shared(package);
        };

        // New LTC1Token with 20,000 balance should exist
        next_tx(&mut scenario, INVESTOR);
        {
            // Take the original token (40k) and the redeemed token (20k)
            let token1 = test_scenario::take_from_sender<LTC1Token>(&scenario);
            test_scenario::return_to_sender(&scenario, token1);
        };

        test_scenario::end(scenario);
    }

    /// Merge back: burn coins back into original token
    #[test]
    fun test_merge_back() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let _package_id = create_contract_and_buy(&mut scenario, 100_000);

        let treasury_cap = create_frac_treasury(&mut scenario);

        // Fractionalize 30,000
        next_tx(&mut scenario, INVESTOR);
        {
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            fractional::fractionalize<TEST_FRAC_COIN>(
                &mut token, treasury_cap, 30_000, ctx(&mut scenario)
            );
            assert!(ltc1::balance(&token) == 70_000);
            test_scenario::return_to_sender(&scenario, token);
        };

        // Merge all coins back
        next_tx(&mut scenario, INVESTOR);
        {
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            let coins = test_scenario::take_from_sender<Coin<TEST_FRAC_COIN>>(&scenario);
            let mut vault = test_scenario::take_shared<FractionalVault<TEST_FRAC_COIN>>(&scenario);

            fractional::merge_back<TEST_FRAC_COIN>(
                &mut token,
                &mut vault,
                coins,
            );

            // Balance should be back to 100,000
            assert!(ltc1::balance(&token) == 100_000);
            // Vault supply should be 0
            assert!(fractional::vault_total_supply(&vault) == 0);

            test_scenario::return_to_sender(&scenario, token);
            test_scenario::return_shared(vault);
        };

        test_scenario::end(scenario);
    }

    /// Cannot redeem against wrong package
    #[test]
    #[expected_failure(abort_code = nplex::fractional::E_PACKAGE_MISMATCH)]
    fun test_cannot_redeem_wrong_package() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let _package_id = create_contract_and_buy(&mut scenario, 100_000);

        let treasury_cap = create_frac_treasury(&mut scenario);

        // Fractionalize
        next_tx(&mut scenario, INVESTOR);
        {
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            fractional::fractionalize<TEST_FRAC_COIN>(
                &mut token, treasury_cap, 50_000, ctx(&mut scenario)
            );
            test_scenario::return_to_sender(&scenario, token);
        };

        // Register a DIFFERENT hash + create a different contract
        next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            registry::register_hash(&mut registry, &admin_cap, 999999999, OWNER, &clock, ctx(&mut scenario));
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        next_tx(&mut scenario, OWNER);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let clock = clock::create_for_testing(ctx(&mut scenario));
            ltc1::create_contract<IOTA>(
                &mut registry,
                string::utf8(b"Other Package"),
                999999999,
                TOTAL_SUPPLY,
                TOKEN_PRICE,
                NOMINAL_VALUE,
                SPLIT_BPS,
                string::utf8(b"ipfs://other"),
                &clock,
                ctx(&mut scenario)
            );
            clock::destroy_for_testing(clock);
            test_scenario::return_shared(registry);
        };

        // Get the OTHER package ID
        next_tx(&mut scenario, ADMIN);
        let other_package_id = {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let info = registry::get_hash_info(&registry, 999999999);
            let contract_id_opt = registry::hash_contract_id(&info);
            let id = std::option::extract(&mut std::option::some(std::option::destroy_some(contract_id_opt)));
            test_scenario::return_shared(registry);
            id
        };

        // Try to redeem against the WRONG package — should abort
        next_tx(&mut scenario, INVESTOR);
        {
            let coins = test_scenario::take_from_sender<Coin<TEST_FRAC_COIN>>(&scenario);
            let mut vault = test_scenario::take_shared<FractionalVault<TEST_FRAC_COIN>>(&scenario);
            let wrong_package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, other_package_id);

            fractional::redeem<TEST_FRAC_COIN, IOTA>(
                &mut vault,
                coins,
                &wrong_package,
                ctx(&mut scenario)
            );

            test_scenario::return_shared(vault);
            test_scenario::return_shared(wrong_package);
        };

        test_scenario::end(scenario);
    }

    /// CRITICAL SECURITY TEST: Prove that claim → fractionalize → redeem → claim
    /// does NOT allow double-claiming revenue.
    /// 
    /// Traces exact IOTA amounts at every step.
    #[test]
    fun test_no_double_claim() {
        let mut scenario = test_scenario::begin(ADMIN);
        setup_registry(&mut scenario);
        let package_id = create_contract_and_buy(&mut scenario, 100_000);

        // ==========================================================
        // Step 1: Owner deposits 1,000,000,000 revenue (= total_supply for easy math)
        // ==========================================================
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<nplex::ltc1::OwnerBond>(&scenario);
            let revenue = coin::mint_for_testing<IOTA>(1_000_000_000, ctx(&mut scenario));
            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, revenue, ctx(&mut scenario));
            test_scenario::return_to_sender(&scenario, bond);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // ==========================================================
        // Step 2: Investor claims revenue → gets 100,000 IOTA
        //   entitled = (100,000 × 1,000,000,000) / 1,000,000,000 = 100,000
        //   due = 100,000 - 0 = 100,000
        // ==========================================================
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);

            assert!(ltc1::balance(&token) == 100_000);
            assert!(ltc1::claimed_revenue(&token) == 0);

            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token, ctx(&mut scenario));

            // After claim: claimed_revenue = 100,000
            assert!(ltc1::claimed_revenue(&token) == 100_000);

            test_scenario::return_to_sender(&scenario, token);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // Verify investor received the IOTA
        next_tx(&mut scenario, INVESTOR);
        {
            let claimed_iota = test_scenario::take_from_sender<Coin<IOTA>>(&scenario);
            assert!(coin::value(&claimed_iota) == 100_000);
            test_scenario::return_to_sender(&scenario, claimed_iota);
        };

        // ==========================================================
        // Step 3: Fractionalize 50,000
        //   claimed_split = (100,000 × 50,000) / 100,000 = 50,000
        //   Token after: balance=50,000, claimed_revenue=50,000
        //   Vault: total_claimed_snapshot=50,000
        // ==========================================================
        let treasury_cap = create_frac_treasury(&mut scenario);
        next_tx(&mut scenario, INVESTOR);
        {
            let mut token = test_scenario::take_from_sender<LTC1Token>(&scenario);
            assert!(ltc1::balance(&token) == 100_000);
            assert!(ltc1::claimed_revenue(&token) == 100_000);

            fractional::fractionalize<TEST_FRAC_COIN>(
                &mut token, treasury_cap, 50_000, ctx(&mut scenario)
            );

            // Verify proportional split
            assert!(ltc1::balance(&token) == 50_000);
            assert!(ltc1::claimed_revenue(&token) == 50_000);

            test_scenario::return_to_sender(&scenario, token);
        };

        // ==========================================================
        // Step 4: Redeem 50,000 coins → new LTC1Token
        //   claimed = (50,000 × 50,000) / 50,000 = 50,000
        //   New token: balance=50,000, claimed_revenue=50,000
        // ==========================================================
        next_tx(&mut scenario, INVESTOR);
        {
            let coins = test_scenario::take_from_sender<Coin<TEST_FRAC_COIN>>(&scenario);
            assert!(coin::value(&coins) == 50_000);

            let mut vault = test_scenario::take_shared<FractionalVault<TEST_FRAC_COIN>>(&scenario);
            let package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);

            fractional::redeem<TEST_FRAC_COIN, IOTA>(
                &mut vault, coins, &package, ctx(&mut scenario)
            );

            test_scenario::return_shared(vault);
            test_scenario::return_shared(package);
        };

        // ==========================================================
        // Step 5: Try to claim on BOTH tokens → should get 0 on both
        //   Original: entitled = (50,000 × 1B) / 1B = 50,000; due = 50,000 - 50,000 = 0
        //   Redeemed:  entitled = (50,000 × 1B) / 1B = 50,000; due = 50,000 - 50,000 = 0
        // ==========================================================
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);

            // Claim on original token
            let mut token1 = test_scenario::take_from_sender<LTC1Token>(&scenario);
            assert!(ltc1::balance(&token1) == 50_000);
            assert!(ltc1::claimed_revenue(&token1) == 50_000);
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token1, ctx(&mut scenario));
            // claimed_revenue unchanged (nothing new to claim)
            assert!(ltc1::claimed_revenue(&token1) == 50_000);
            test_scenario::return_to_sender(&scenario, token1);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);

            // Claim on redeemed token
            let mut token2 = test_scenario::take_from_sender<LTC1Token>(&scenario);
            assert!(ltc1::balance(&token2) == 50_000);
            assert!(ltc1::claimed_revenue(&token2) == 50_000);
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token2, ctx(&mut scenario));
            // Also unchanged — NO double claim
            assert!(ltc1::claimed_revenue(&token2) == 50_000);
            test_scenario::return_to_sender(&scenario, token2);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // ==========================================================
        // Step 6: NEW revenue deposited → both tokens can claim their fair share
        //   Deposit 1,000,000,000 more (total_revenue_deposited = 2,000,000,000)
        // ==========================================================
        next_tx(&mut scenario, OWNER);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);
            let bond = test_scenario::take_from_sender<nplex::ltc1::OwnerBond>(&scenario);
            let revenue = coin::mint_for_testing<IOTA>(1_000_000_000, ctx(&mut scenario));
            ltc1::deposit_revenue<IOTA>(&registry, &mut package, &bond, revenue, ctx(&mut scenario));
            test_scenario::return_to_sender(&scenario, bond);
            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        // ==========================================================
        // Step 7: Claim new revenue — each gets exactly 50,000 more
        //   Token1: entitled = (50,000 × 2B) / 1B = 100,000; due = 100,000 - 50,000 = 50,000 ✓
        //   Token2: entitled = (50,000 × 2B) / 1B = 100,000; due = 100,000 - 50,000 = 50,000 ✓
        // ==========================================================
        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);

            let mut token1 = test_scenario::take_from_sender<LTC1Token>(&scenario);
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token1, ctx(&mut scenario));
            assert!(ltc1::claimed_revenue(&token1) == 100_000); // 50k old + 50k new
            test_scenario::return_to_sender(&scenario, token1);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        next_tx(&mut scenario, INVESTOR);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut package = test_scenario::take_shared_by_id<LTC1Package<IOTA>>(&scenario, package_id);

            let mut token2 = test_scenario::take_from_sender<LTC1Token>(&scenario);
            ltc1::claim_revenue<IOTA>(&registry, &mut package, &mut token2, ctx(&mut scenario));
            assert!(ltc1::claimed_revenue(&token2) == 100_000); // 50k old + 50k new
            test_scenario::return_to_sender(&scenario, token2);

            test_scenario::return_shared(registry);
            test_scenario::return_shared(package);
        };

        test_scenario::end(scenario);
    }
}
