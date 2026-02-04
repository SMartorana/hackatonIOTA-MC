# Tests

## Registry Tests (`registry_tests.move`)

1. `test_register_and_validate_hash`
2. `test_register_same_hash_twice`
3. `test_unregistered_hash_is_invalid`
4. `test_revoked_hash_is_invalid`
5. `test_non_admin_cannot_register_hash`
6. `test_non_admin_cannot_revoke_hash`
7. `test_non_admin_cannot_unrevoke_hash`
8. `test_same_ltc1_cannot_use_same_hash_twice`
9. `test_different_ltc1_cannot_use_same_hash_twice`
10. `test_ltc1_cannot_use_unapproved_hash`
11. `test_ltc1_cannot_use_revoked_hash`
12. `test_unauthorized_executor_cannot_bind`
13. `test_authorize_and_consume_transfer_ticket`
14. `test_cannot_consume_ticket_with_wrong_owner`
15. `test_unauthorized_executor_cannot_consume_ticket`

## LTC1 Tests (`ltc1_tests.move`)

1. `test_end_to_end_flow`
2. `test_supply_split_enforcement`
3. `test_create_contract_not_registered_hash`
4. `test_create_contract_unauthorized_witness`
5. `test_owner_bond_transfer`
6. `test_withdraw_funding`
7. `test_complex_lifecycle_flow`
8. `test_create_contract_supply_too_low`
9. `test_create_contract_split_too_high`
10. `test_double_claim`
