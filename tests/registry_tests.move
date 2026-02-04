// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// Unit tests for NPLEX Registry
/// Tests hash registration, validation, revocation, and access control

#[test_only]
#[allow(implicit_const_copy)]
module nplex::registry_tests {
    use nplex::registry::{Self, NPLEXRegistry, NPLEXAdminCap};
    use iota::test_scenario;

    // Test addresses
    #[allow(unused_const)]
    const ADMIN: address = @0xAD;
    #[allow(unused_const)]
    const ALICE: address = @0xA;
    #[allow(unused_const)]
    const Verified_hash: u256 = 1;
    #[allow(unused_const)]
    const Unverified_hash: u256 = 2;
    #[allow(unused_const)]  
    const Revoked_hash: u256 = 3;
    #[allow(unused_const)]
    const BOB: address = @0xB;

    // Witness for testing
    public struct TestWitness has drop {}

    // Witness for unauthorized testing
    public struct UnauthorizedWitness has drop {}

    // Fixture to initialize the registry and register a hashes
    #[test_only]
    fun fixture_init_registry_and_setup_hashes(scenario: &mut test_scenario::Scenario) {
        // 1. Initialize
        registry::init_for_testing(test_scenario::ctx(scenario));
        
        // 2. Commit initialization transaction
        test_scenario::next_tx(scenario, ADMIN);
        
        // 3. Register hash
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);
            
            registry::register_hash(&mut registry, &admin_cap, Verified_hash, ADMIN, test_scenario::ctx(scenario));
            // Authorize TestWitness
            registry::add_executor<TestWitness>(&mut registry, &admin_cap);
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario, admin_cap);
        };

        // 4. register Revoked_hash
        test_scenario::next_tx(scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);
            
            registry::register_hash(&mut registry, &admin_cap, Revoked_hash, ADMIN, test_scenario::ctx(scenario));
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario, admin_cap);
        };
        // 5. revoke Revoked_hash
        test_scenario::next_tx(scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(scenario);
            
            registry::revoke_hash(&mut registry, &admin_cap, Revoked_hash);
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(scenario, admin_cap);
        };  
    }

    #[test]
    fun test_register_and_validate_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Verify hash is valid
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            assert!(registry::is_valid_hash(&registry, Verified_hash), 0);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_HASH_ALREADY_USED)]
    fun test_register_same_hash_twice() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Register hash first time (Success)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::register_hash(&mut registry, &admin_cap, Verified_hash, ADMIN, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };
        
        // Register same hash second time (Fail)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            // This should abort with E_HASH_ALREADY_USED
            registry::register_hash(&mut registry, &admin_cap, Verified_hash, ADMIN, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_unregistered_hash_is_invalid() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture to set up common state
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Check unregistered hash
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            // Should be invalid
            assert!(!registry::is_valid_hash(&registry, Unverified_hash), 0);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    fun test_revoked_hash_is_invalid() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture (already contains Revoked_hash which is revoked)
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Verify Revoked_hash is invalid
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            assert!(!registry::is_valid_hash(&registry, Revoked_hash), 1);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = test_scenario::EEmptyInventory)]
    fun test_non_admin_cannot_register_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Initialize registry (ADMIN gets the admin_cap)
        {
            registry::init_for_testing(test_scenario::ctx(&mut scenario));
        };
        
        // Alice (non-admin) tries to register a hash
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            // Alice tries to take admin_cap but doesn't have it!
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            let document_hash: u256 = 4;
            
            registry::register_hash(&mut registry, &admin_cap, document_hash, ADMIN, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = test_scenario::EEmptyInventory)]
    fun test_non_admin_cannot_revoke_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Alice tries to revoke the hash
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            // Alice tries to take admin_cap but doesn't have it!
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::revoke_hash(&mut registry, &admin_cap, Verified_hash);
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = test_scenario::EEmptyInventory)]
    fun test_non_admin_cannot_unrevoke_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Admin revokes first
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::revoke_hash(&mut registry, &admin_cap, Verified_hash);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };
        
        // Alice tries to unrevoke the hash
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            // Alice tries to take admin_cap but doesn't have it!
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::unrevoke_hash(&mut registry, &admin_cap, Verified_hash);
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_HASH_ALREADY_USED)]
    fun test_same_ltc1_cannot_use_same_hash_twice() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // mark_hash_used first time (Success)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            // In unit tests, we can generate IDs from addresses
            let id1 = object::id_from_address(@0x101);
            
            let claim = registry::claim_hash(&mut registry, Verified_hash, test_scenario::ctx(&mut scenario));
            registry::bind_executor(&mut registry, claim, id1, TestWitness {});
            
            test_scenario::return_shared(registry);
        };
        
        // mark_hash_used second time (Fail)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            let id2 = object::id_from_address(@0x101);
            
            // This should abort with E_HASH_ALREADY_USED
            let claim = registry::claim_hash(&mut registry, Verified_hash, test_scenario::ctx(&mut scenario));
            registry::bind_executor(&mut registry, claim, id2, TestWitness {});
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_HASH_ALREADY_USED)]
    fun test_different_ltc1_cannot_use_same_hash_twice() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // mark_hash_used first time (Success)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            // In unit tests, we can generate IDs from addresses
            let id1 = object::id_from_address(@0x101);
            
            let claim = registry::claim_hash(&mut registry, Verified_hash, test_scenario::ctx(&mut scenario));
            registry::bind_executor(&mut registry, claim, id1, TestWitness {});
            
            test_scenario::return_shared(registry);
        };
        
        // mark_hash_used second time (Fail)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            let id2 = object::id_from_address(@0x102);
            
            // This should abort with E_HASH_ALREADY_USED
            let claim = registry::claim_hash(&mut registry, Verified_hash, test_scenario::ctx(&mut scenario));
            registry::bind_executor(&mut registry, claim, id2, TestWitness {});
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_HASH_NOT_APPROVED)]
    fun test_ltc1_cannot_use_unapproved_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Try to use unverified hash
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let id = object::id_from_address(@0x103);
            
            // This should abort with E_HASH_NOT_APPROVED
            let claim = registry::claim_hash(&mut registry, Unverified_hash, test_scenario::ctx(&mut scenario));
            registry::bind_executor(&mut registry, claim, id, TestWitness {});
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    #[test]
    #[expected_failure(abort_code = registry::E_HASH_REVOKED)]
    fun test_ltc1_cannot_use_revoked_hash() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        // Try to use revoked hash
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let id = object::id_from_address(@0x104);
            
            // This should abort with E_HASH_REVOKED
            let claim = registry::claim_hash(&mut registry, Revoked_hash, test_scenario::ctx(&mut scenario));
            registry::bind_executor(&mut registry, claim, id, TestWitness {});
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_UNAUTHORIZED_EXECUTOR)]
    fun test_unauthorized_executor_cannot_bind() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture (authorizes TestWitness, but NOT UnauthorizedWitness)
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let id = object::id_from_address(@0x105);
            
            // This should fail because UnauthorizedWitness is not in the table
            let claim = registry::claim_hash(&mut registry, Verified_hash, test_scenario::ctx(&mut scenario));
            registry::bind_executor(&mut registry, claim, id, UnauthorizedWitness {});
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    // Transfer Logic Tests
    #[test]
    fun test_authorize_and_consume_transfer_ticket() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // Use fixture
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        let package_id_addr = @0x123;
        let package_id = object::id_from_address(package_id_addr);
        let new_owner = ALICE;

        // 1. Authorize Transfer (Admin)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::authorize_transfer(&mut registry, &admin_cap, package_id, new_owner);
            
            // Assert: Ticket Created
            assert!(registry::is_transfer_authorized(&registry, package_id), 1);
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 2. Consume Ticket (Executor)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            // Should succeed with correct witness and parameters
            registry::consume_transfer_ticket(&mut registry, package_id, new_owner, TestWitness {});
            
            // Assert: Ticket Consumed
            assert!(!registry::is_transfer_authorized(&registry, package_id), 2);
            
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_TRANSFER_NOT_AUTHORIZED)]
    fun test_cannot_consume_ticket_with_wrong_owner() {
        let mut scenario = test_scenario::begin(ADMIN);
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        let package_id = object::id_from_address(@0x123);
        let authorized_owner = ALICE;
        let wrong_owner = BOB;

        // 1. Authorize for ALICE
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::authorize_transfer(&mut registry, &admin_cap, package_id, authorized_owner);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 2. Try to consume for BOB (Fail)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            registry::consume_transfer_ticket(&mut registry, package_id, wrong_owner, TestWitness {});
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_UNAUTHORIZED_EXECUTOR)]
    fun test_unauthorized_executor_cannot_consume_ticket() {
        let mut scenario = test_scenario::begin(ADMIN);
        fixture_init_registry_and_setup_hashes(&mut scenario);
        
        let package_id = object::id_from_address(@0x123);
        let new_owner = ALICE;

        // 1. Authorize
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            registry::authorize_transfer(&mut registry, &admin_cap, package_id, new_owner);
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 2. Try to consume with UnauthorizedWitness (Fail)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            registry::consume_transfer_ticket(&mut registry, package_id, new_owner, UnauthorizedWitness {});
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }
    #[test]
    fun test_claim_hash_authorized_success() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // 0. Initialize
        {
            registry::init_for_testing(test_scenario::ctx(&mut scenario));
        };

        // 1. Register hash with authorized creator (ALICE)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::register_hash(&mut registry, &admin_cap, Verified_hash, ALICE, test_scenario::ctx(&mut scenario));
            // Authorize TestWitness
            registry::add_executor<TestWitness>(&mut registry, &admin_cap);

            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 2. ALICE claims the hash (Success)
        test_scenario::next_tx(&mut scenario, ALICE);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let id = object::id_from_address(@0x106);
            
            let claim = registry::claim_hash(&mut registry, Verified_hash, test_scenario::ctx(&mut scenario));
            registry::bind_executor(&mut registry, claim, id, TestWitness {});
            
            assert!(registry::is_hash_used(&registry, Verified_hash), 0);

            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = registry::E_UNAUTHORIZED_CREATOR)]
    fun test_claim_hash_unauthorized_fail() {
        let mut scenario = test_scenario::begin(ADMIN);
        
        // 0. Initialize
        {
            registry::init_for_testing(test_scenario::ctx(&mut scenario));
        };

        // 1. Register hash with authorized creator (ALICE)
        test_scenario::next_tx(&mut scenario, ADMIN);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            let admin_cap = test_scenario::take_from_sender<NPLEXAdminCap>(&scenario);
            
            registry::register_hash(&mut registry, &admin_cap, Verified_hash, ALICE, test_scenario::ctx(&mut scenario));
            
            test_scenario::return_shared(registry);
            test_scenario::return_to_sender(&scenario, admin_cap);
        };

        // 2. BOB tries to claim the hash (Fail)
        test_scenario::next_tx(&mut scenario, BOB);
        {
            let mut registry = test_scenario::take_shared<NPLEXRegistry>(&scenario);
            
            // This should abort with E_UNAUTHORIZED_CREATOR
            let claim = registry::claim_hash(&mut registry, Verified_hash, test_scenario::ctx(&mut scenario));
            
            // Should not reach here
            registry::burn_hash_claim(claim);
            test_scenario::return_shared(registry);
        };
        
        test_scenario::end(scenario);
    }

}
