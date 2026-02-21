
#[test_only]
module nplex::did_tests {
    use iota::test_scenario;
    use iota::clock;
    use iota_identity::controller::{Self, ControllerCap};
    use iota_identity::identity;
    use iota_notarization::notarization::{Self, Notarization};
    use iota_notarization::dynamic_notarization;
    use iota_notarization::timelock;
    
    use nplex::registry::{Self, NPLEXRegistry, NPLEXAdminCap};

    const ADMIN: address = @0xAD;
    const INSTITUTION_DID: address = @0x1;
    const INVESTOR_DID: address = @0x2;

    // Helper to create a dummy ID for a DID
    fun did_id(addr: address): ID { object::id_from_address(addr) }

    /// Helper: create a real backing Notarization<u256> for tests
    fun create_backing_notarization(scenario: &mut test_scenario::Scenario) {
        let clock = clock::create_for_testing(test_scenario::ctx(scenario));
        let state = notarization::new_state_from_generic<u256>(99u256, option::none());
        let notarization_obj = dynamic_notarization::new<u256>(
            state, option::none(), option::none(), timelock::none(), &clock, test_scenario::ctx(scenario)
        );
        dynamic_notarization::transfer(notarization_obj, ADMIN, &clock, test_scenario::ctx(scenario));
        clock::destroy_for_testing(clock);
    }

    #[test]
    fun test_did_lifecycle() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // 1. Initialize Registry
        {
            registry::init_for_testing(test_scenario::ctx(&mut scenario));
        };

        // 2. Create backing notarization
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            create_backing_notarization(&mut scenario);
        };

        // 3. Approve Institution DID
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let backing_notarization = test_scenario::take_from_sender<Notarization<u256>>(&scenario);
            
            registry::approve_identity(
                &mut registry,
                &admin_cap,
                did_id(INSTITUTION_DID),
                registry::role_institution(), b"mock_vc_jwt_data",
                &backing_notarization,
            );

            test_scenario::return_to_sender(&scenario, backing_notarization);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 3. Verify Institution DID (Success)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            // Create a fake token that controls INSTITUTION_DID
            let token = controller::create_delegation_token_for_testing(
                did_id(INSTITUTION_DID),
                test_scenario::ctx(&mut scenario)
            );

            // Verify
            registry::verify_identity(&registry, &token, registry::role_institution());

            controller::destroy_delegation_token_for_testing(token);
            test_scenario::return_shared(registry);
        };

        // Revoke DID
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let backing_notarization = test_scenario::take_from_sender<Notarization<u256>>(&scenario);
            
            registry::revoke_identity(&mut registry, &admin_cap, did_id(INSTITUTION_DID), &backing_notarization);

            test_scenario::return_to_sender(&scenario, backing_notarization);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 5. Verify Revoked DID (Fail)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            let token = controller::create_delegation_token_for_testing(
                did_id(INSTITUTION_DID),
                test_scenario::ctx(&mut scenario)
            );

            // This should crash if we weren't handling it, but we can't assert failure inside a block easily without a separate test function.
            // For this single lifecycle test, we just want to ensure the flow works.
            // To test failure properly, we'll use specific test functions below.
            
            controller::destroy_delegation_token_for_testing(token);
            test_scenario::return_shared(registry);
        };

        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_IDENTITY_NOT_APPROVED)]
    fun test_verify_revoked_did_fails() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Init
        registry::init_for_testing(test_scenario::ctx(&mut scenario));

        // Approve then Revoke
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            create_backing_notarization(&mut scenario);
        };
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let backing_notarization = test_scenario::take_from_sender<Notarization<u256>>(&scenario);
            
            registry::approve_identity(&mut registry, &admin_cap, did_id(INSTITUTION_DID), registry::role_institution(), b"mock_vc_jwt_data", &backing_notarization);
            registry::revoke_identity(&mut registry, &admin_cap, did_id(INSTITUTION_DID), &backing_notarization);

            test_scenario::return_to_sender(&scenario, backing_notarization);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // Try Verify
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let token = controller::create_delegation_token_for_testing(did_id(INSTITUTION_DID), test_scenario::ctx(&mut scenario));
            
            registry::verify_identity(&registry, &token, registry::role_institution()); // Abort here

            controller::destroy_delegation_token_for_testing(token);
            test_scenario::return_shared(registry);
        };
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_IDENTITY_NOT_APPROVED)]
    fun test_verify_unknown_did_fails() {
        let mut scenario = test_scenario::begin(ADMIN);
        registry::init_for_testing(test_scenario::ctx(&mut scenario));

        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            // Some random DID
            let token = controller::create_delegation_token_for_testing(did_id(@0x999), test_scenario::ctx(&mut scenario));
            
            registry::verify_identity(&registry, &token, registry::role_institution()); // Abort here

            controller::destroy_delegation_token_for_testing(token);
            test_scenario::return_shared(registry);
        };
        test_scenario::end(scenario);
    }

    #[test]
    fun test_role_checks() {
        let mut scenario = test_scenario::begin(ADMIN);
        registry::init_for_testing(test_scenario::ctx(&mut scenario));

        // Setup: Institution=ROLE_INSTITUTION, Investor=ROLE_INVESTOR
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            create_backing_notarization(&mut scenario);
        };
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let backing_notarization = test_scenario::take_from_sender<Notarization<u256>>(&scenario);
            
            registry::approve_identity(&mut registry, &admin_cap, did_id(INSTITUTION_DID), registry::role_institution(), b"mock_vc_jwt_data", &backing_notarization);
            registry::approve_identity(&mut registry, &admin_cap, did_id(INVESTOR_DID), registry::role_investor(), b"mock_vc_jwt_data", &backing_notarization);

            test_scenario::return_to_sender(&scenario, backing_notarization);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // Verify correct roles
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            let token_inst = controller::create_delegation_token_for_testing(did_id(INSTITUTION_DID), test_scenario::ctx(&mut scenario));
            let token_inv = controller::create_delegation_token_for_testing(did_id(INVESTOR_DID), test_scenario::ctx(&mut scenario));

            // Institution checks
            registry::verify_identity(&registry, &token_inst, registry::role_institution());
            
            // Investor checks
            registry::verify_identity(&registry, &token_inv, registry::role_investor());

            controller::destroy_delegation_token_for_testing(token_inst);
            controller::destroy_delegation_token_for_testing(token_inv);
            test_scenario::return_shared(registry);
        };

         test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_IDENTITY_WRONG_ROLE)]
    fun test_institution_cannot_act_as_investor() {
        let mut scenario = test_scenario::begin(ADMIN);
        registry::init_for_testing(test_scenario::ctx(&mut scenario));

        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            create_backing_notarization(&mut scenario);
        };
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let backing_notarization = test_scenario::take_from_sender<Notarization<u256>>(&scenario);
            // Register as Institution only
            registry::approve_identity(&mut registry, &admin_cap, did_id(INSTITUTION_DID), registry::role_institution(), b"mock_vc_jwt_data", &backing_notarization);
            test_scenario::return_to_sender(&scenario, backing_notarization);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let token = controller::create_delegation_token_for_testing(did_id(INSTITUTION_DID), test_scenario::ctx(&mut scenario));
            
            // Try to verify as Investor
            registry::verify_identity(&registry, &token, registry::role_investor()); // Should abort

            controller::destroy_delegation_token_for_testing(token);
            test_scenario::return_shared(registry);
        };
        test_scenario::end(scenario);
    }

    // ==========================================================================
    // Realistic DID Tests — using actual Identity + ControllerCap + borrow flow
    // ==========================================================================

    #[test]
    fun test_realistic_did_verification() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        // 1. Initialize NPLEX Registry
        registry::init_for_testing(test_scenario::ctx(&mut scenario));

        // 2. INSTITUTION_DID creates a real on-chain Identity
        test_scenario::next_tx(&mut scenario, INSTITUTION_DID);
        let institution_identity_id = identity::new_with_controller(
            option::none(),           // no DID doc bytes (not needed for our test)
            INSTITUTION_DID,          // controller address
            false,                    // can_delegate
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // 3. INVESTOR_DID creates a real on-chain Identity
        test_scenario::next_tx(&mut scenario, INVESTOR_DID);
        let investor_identity_id = identity::new_with_controller(
            option::none(),
            INVESTOR_DID,
            false,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // 4. Create backing notarization
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            create_backing_notarization(&mut scenario);
        };

        // 5. Admin whitelists both real Identity IDs
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let backing_notarization = test_scenario::take_from_sender<Notarization<u256>>(&scenario);

            // Whitelist institution with role_institution, investor with role_investor
            registry::approve_identity(
                &mut registry, &admin_cap,
                institution_identity_id,
                registry::role_institution(), b"mock_vc_jwt_data",
                &backing_notarization,
            );
            registry::approve_identity(
                &mut registry, &admin_cap,
                investor_identity_id,
                registry::role_investor(), b"mock_vc_jwt_data",
                &backing_notarization,
            );

            test_scenario::return_to_sender(&scenario, backing_notarization);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 5. Institution borrows DelegationToken from their real ControllerCap
        //    and verifies identity — this mirrors the exact frontend PTB flow
        test_scenario::next_tx(&mut scenario, INSTITUTION_DID);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut controller_cap = test_scenario::take_from_sender<ControllerCap>(&scenario);

            // Borrow the DelegationToken (hot potato pattern)
            let (token, borrow) = controller::borrow(&mut controller_cap);

            // Verify — this checks token.controller_of == institution_identity_id
            registry::verify_identity(&registry, &token, registry::role_institution());

            // Return the token (mandatory — hot potato)
            controller::put_back(&mut controller_cap, token, borrow);

            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, controller_cap);
        };

        // 6. Investor does the same
        test_scenario::next_tx(&mut scenario, INVESTOR_DID);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut controller_cap = test_scenario::take_from_sender<ControllerCap>(&scenario);

            let (token, borrow) = controller::borrow(&mut controller_cap);
            registry::verify_identity(&registry, &token, registry::role_investor());
            controller::put_back(&mut controller_cap, token, borrow);

            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, controller_cap);
        };

        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_IDENTITY_WRONG_ROLE)]
    fun test_realistic_wrong_role_fails() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        // 1. Initialize NPLEX Registry
        registry::init_for_testing(test_scenario::ctx(&mut scenario));

        // 2. INSTITUTION_DID creates an Identity
        test_scenario::next_tx(&mut scenario, INSTITUTION_DID);
        let institution_identity_id = identity::new_with_controller(
            option::none(),
            INSTITUTION_DID,
            false,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // 3. Create backing notarization and whitelist as Institution
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            create_backing_notarization(&mut scenario);
        };
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let backing_notarization = test_scenario::take_from_sender<Notarization<u256>>(&scenario);
            registry::approve_identity(
                &mut registry, &admin_cap,
                institution_identity_id,
                registry::role_institution(), b"mock_vc_jwt_data",
                &backing_notarization,
            );
            test_scenario::return_to_sender(&scenario, backing_notarization);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 4. Institution tries to verify as Investor — should abort!
        test_scenario::next_tx(&mut scenario, INSTITUTION_DID);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut controller_cap = test_scenario::take_from_sender<ControllerCap>(&scenario);

            let (token, borrow) = controller::borrow(&mut controller_cap);

            // This should abort with E_IDENTITY_WRONG_ROLE
            registry::verify_identity(&registry, &token, registry::role_investor());

            controller::put_back(&mut controller_cap, token, borrow);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, controller_cap);
        };

        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_IDENTITY_NOT_APPROVED)]
    fun test_realistic_revoked_identity_fails() {
        let mut scenario = test_scenario::begin(ADMIN);
        let clock = clock::create_for_testing(test_scenario::ctx(&mut scenario));

        // 1. Initialize NPLEX Registry
        registry::init_for_testing(test_scenario::ctx(&mut scenario));

        // 2. INSTITUTION_DID creates an Identity
        test_scenario::next_tx(&mut scenario, INSTITUTION_DID);
        let institution_identity_id = identity::new_with_controller(
            option::none(),
            INSTITUTION_DID,
            false,
            &clock,
            test_scenario::ctx(&mut scenario),
        );

        // 3. Create backing notarization, approve, then revoke
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            create_backing_notarization(&mut scenario);
        };
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            let backing_notarization = test_scenario::take_from_sender<Notarization<u256>>(&scenario);
            registry::approve_identity(
                &mut registry, &admin_cap,
                institution_identity_id,
                registry::role_institution(), b"mock_vc_jwt_data",
                &backing_notarization,
            );
            registry::revoke_identity(
                &mut registry, &admin_cap,
                institution_identity_id,
                &backing_notarization,
            );
            test_scenario::return_to_sender(&scenario, backing_notarization);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 4. Institution tries to verify — should abort!
        test_scenario::next_tx(&mut scenario, INSTITUTION_DID);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let mut controller_cap = test_scenario::take_from_sender<ControllerCap>(&scenario);

            let (token, borrow) = controller::borrow(&mut controller_cap);

            // Should abort with E_IDENTITY_NOT_APPROVED
            registry::verify_identity(&registry, &token, registry::role_institution());

            controller::put_back(&mut controller_cap, token, borrow);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, controller_cap);
        };

        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }
}
