// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// NPLEX Events Module
///
/// Centralizes all event definitions to improve discoverability and indexing.
module nplex::events {
    // No imports needed if using fully qualified paths for types, but we need event::emit

    // ==================== Events ====================

    /// Emitted when a new LTC1 Contract/Package is created
    public struct ContractCreated has copy, drop {
        package_id: iota::object::ID,
        creator: address,
        nominal_value: u64
    }

    /// Emitted when an investor buys LTC1 tokens
    public struct TokenPurchased has copy, drop {
        package_id: iota::object::ID,
        investor: address,
        amount: u64, // tokens bought
        cost: u64    // coin paid
    }

    /// Emitted when the owner deposits revenue into the pool
    public struct RevenueDeposited has copy, drop {
        package_id: iota::object::ID,
        amount: u64
    }

    /// Event emitted when a new FractionalVault is created
    public struct VaultCreated has copy, drop {
        vault_id: iota::object::ID,
        package_id: iota::object::ID,
        fraction_type: std::ascii::String,
        amount: u64,
        minter: address,
    }

    /// Event emitted when a vault becomes empty (ready for manual destruction)
    public struct VaultEmpty has copy, drop {
        vault_id: iota::object::ID,
        fraction_type: std::ascii::String,
    }

    // ==================== Emitters ====================

    public fun emit_contract_created(
        package_id: iota::object::ID,
        creator: address,
        nominal_value: u64
    ) {
        iota::event::emit(ContractCreated {
            package_id,
            creator,
            nominal_value
        });
    }

    public fun emit_token_purchased(
        package_id: iota::object::ID,
        investor: address,
        amount: u64,
        cost: u64
    ) {
        iota::event::emit(TokenPurchased {
            package_id,
            investor,
            amount,
            cost
        });
    }

    public fun emit_revenue_deposited(
        package_id: iota::object::ID,
        amount: u64
    ) {
        iota::event::emit(RevenueDeposited {
            package_id,
            amount
        });
    }

    public fun emit_vault_created(
        vault_id: iota::object::ID,
        package_id: iota::object::ID,
        fraction_type: std::ascii::String,
        amount: u64,
        minter: address,
    ) {
        iota::event::emit(VaultCreated {
            vault_id,
            package_id,
            fraction_type,
            amount,
            minter
        });
    }

    public fun emit_vault_empty(
        vault_id: iota::object::ID,
        fraction_type: std::ascii::String,
    ) {
        iota::event::emit(VaultEmpty {
            vault_id,
            fraction_type
        });
    }
}
