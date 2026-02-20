
#[test_only]
module nplex::did_tests {
    use iota::test_scenario;
    use iota_identity::controller;
    
    use nplex::registry::{Self, NPLEXRegistry, NPLEXAdminCap};

    const ADMIN: address = @0xAD;
    const INSTITUTION_DID: address = @0x1;
    const INVESTOR_DID: address = @0x2;

    // Helper to create a dummy ID for a DID
    fun did_id(addr: address): ID { object::id_from_address(addr) }

    #[test]
    fun test_did_lifecycle() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // 1. Initialize Registry
        {
            registry::init_for_testing(test_scenario::ctx(&mut scenario));
        };

        // 2. Approve Institution DID
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::approve_identity(
                &mut registry,
                &admin_cap,
                did_id(INSTITUTION_DID),
                registry::role_institution()
            );

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

        // 4. Revoke DID
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::revoke_identity(&mut registry, &admin_cap, did_id(INSTITUTION_DID));

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
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::approve_identity(&mut registry, &admin_cap, did_id(INSTITUTION_DID), registry::role_institution());
            registry::revoke_identity(&mut registry, &admin_cap, did_id(INSTITUTION_DID));

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
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::approve_identity(&mut registry, &admin_cap, did_id(INSTITUTION_DID), registry::role_institution());
            registry::approve_identity(&mut registry, &admin_cap, did_id(INVESTOR_DID), registry::role_investor());

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
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            // Register as Institution only
            registry::approve_identity(&mut registry, &admin_cap, did_id(INSTITUTION_DID), registry::role_institution());
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
}
