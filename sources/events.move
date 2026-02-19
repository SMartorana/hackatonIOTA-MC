// Copyright (c) 2026 Federico Abrignani. All rights reserved.
/// NPLEX Events Module
///
/// Centralizes all event definitions to improve discoverability and indexing.
module nplex::events {

    // ==================== Registry Events ====================

    /// Emitted when a notarization is registered in the registry
    public struct NotarizationRegistered has copy, drop {
        notarization_id: iota::object::ID,
        document_hash: u256,
        authorized_creator: address,
        auditor: address,
        timestamp: u64,
    }

    /// Emitted when a notarization is revoked
    public struct NotarizationRevoked has copy, drop {
        notarization_id: iota::object::ID,
    }

    /// Emitted when a notarization revocation is undone
    public struct NotarizationUnrevoked has copy, drop {
        notarization_id: iota::object::ID,
    }

    /// Emitted when the authorized creator for a notarization is updated
    public struct AuthorizedCreatorUpdated has copy, drop {
        notarization_id: iota::object::ID,
        new_creator: address,
    }

    /// Emitted when an executor module is added
    public struct ExecutorAdded has copy, drop {
        executor_type: std::ascii::String,
    }

    /// Emitted when an executor module is removed
    public struct ExecutorRemoved has copy, drop {
        executor_type: std::ascii::String,
    }

    /// Emitted when a bond transfer is authorized by NPLEX
    public struct TransferAuthorized has copy, drop {
        contract_id: iota::object::ID,
        new_owner: address,
        notarization_id: iota::object::ID,
    }

    /// Emitted when a transfer ticket is consumed
    public struct TransferConsumed has copy, drop {
        bond_id: iota::object::ID,
        new_owner: address,
    }

    /// Emitted when a sales toggle is authorized by NPLEX
    public struct SalesToggleAuthorized has copy, drop {
        contract_id: iota::object::ID,
        target_state: bool,
        notarization_id: iota::object::ID,
    }

    /// Emitted when a sales toggle ticket is consumed
    public struct SalesToggleConsumed has copy, drop {
        contract_id: iota::object::ID,
        new_state: bool,
    }

    // ==================== LTC1 Events ====================

    /// Emitted when a new LTC1 Contract/Package is created
    public struct ContractCreated has copy, drop {
        package_id: iota::object::ID,
        creator: address,
        nominal_value: u64
    }

    /// Emitted when the owner DID is set or updated on an LTC1 Package
    public struct OwnerDidUpdated has copy, drop {
        package_id: iota::object::ID,
        owner_did: option::Option<address>,
    }

    /// Emitted when an Identity is approved/whitelisted
    public struct IdentityApproved has copy, drop {
        identity_id: iota::object::ID,
        role: u8,
    }

    /// Emitted when an Identity is revoked from the whitelist
    public struct IdentityRevoked has copy, drop {
        identity_id: iota::object::ID,
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

    /// Emitted when the owner withdraws funding from the pool
    public struct FundingWithdrawn has copy, drop {
        package_id: iota::object::ID,
        amount: u64,
        recipient: address,
    }

    /// Emitted when the owner claims their revenue share
    public struct RevenueClaimedOwner has copy, drop {
        package_id: iota::object::ID,
        amount: u64,
        owner: address,
    }

    /// Emitted when an investor claims their revenue share
    public struct RevenueClaimedInvestor has copy, drop {
        package_id: iota::object::ID,
        token_id: iota::object::ID,
        amount: u64,
        investor: address,
    }

    /// Emitted when an owner bond is transferred
    public struct BondTransferred has copy, drop {
        bond_id: iota::object::ID,
        package_id: iota::object::ID,
        new_owner: address,
    }

    /// Emitted when sales state is toggled
    public struct SalesToggled has copy, drop {
        package_id: iota::object::ID,
        new_state: bool,
    }

    // ==================== Fractional Events ====================

    /// Event emitted when a new FractionalVault is created
    public struct VaultCreated has copy, drop {
        vault_id: iota::object::ID,
        package_id: iota::object::ID,
        fraction_type: std::ascii::String,
        amount: u64,
        minter: address,
    }

    /// Event emitted when fractions are redeemed for a new LTC1Token
    public struct FractionRedeemed has copy, drop {
        vault_id: iota::object::ID,
        amount: u64,
        redeemer: address,
    }

    /// Event emitted when fractions are merged back into an existing LTC1Token
    public struct FractionMergedBack has copy, drop {
        vault_id: iota::object::ID,
        token_id: iota::object::ID,
        amount: u64,
    }

    /// Event emitted when a vault becomes empty (ready for manual destruction)
    public struct VaultEmpty has copy, drop {
        vault_id: iota::object::ID,
        fraction_type: std::ascii::String,
    }

    /// Event emitted when an empty vault is destroyed
    public struct VaultDestroyed has copy, drop {
        vault_id: iota::object::ID,
    }

    // ==================== Registry Emitters ====================

    public(package) fun emit_notarization_registered(
        notarization_id: iota::object::ID,
        document_hash: u256,
        authorized_creator: address,
        auditor: address,
        timestamp: u64,
    ) {
        iota::event::emit(NotarizationRegistered {
            notarization_id,
            document_hash,
            authorized_creator,
            auditor,
            timestamp,
        });
    }

    public(package) fun emit_notarization_revoked(
        notarization_id: iota::object::ID,
    ) {
        iota::event::emit(NotarizationRevoked { notarization_id });
    }

    public(package) fun emit_notarization_unrevoked(
        notarization_id: iota::object::ID,
    ) {
        iota::event::emit(NotarizationUnrevoked { notarization_id });
    }

    public(package) fun emit_authorized_creator_updated(
        notarization_id: iota::object::ID,
        new_creator: address,
    ) {
        iota::event::emit(AuthorizedCreatorUpdated {
            notarization_id,
            new_creator,
        });
    }

    public(package) fun emit_executor_added(
        executor_type: std::ascii::String,
    ) {
        iota::event::emit(ExecutorAdded { executor_type });
    }

    public(package) fun emit_executor_removed(
        executor_type: std::ascii::String,
    ) {
        iota::event::emit(ExecutorRemoved { executor_type });
    }

    public(package) fun emit_transfer_authorized(
        contract_id: iota::object::ID,
        new_owner: address,
        notarization_id: iota::object::ID,
    ) {
        iota::event::emit(TransferAuthorized {
            contract_id,
            new_owner,
            notarization_id,
        });
    }

    public(package) fun emit_transfer_consumed(
        bond_id: iota::object::ID,
        new_owner: address,
    ) {
        iota::event::emit(TransferConsumed { bond_id, new_owner });
    }

    public(package) fun emit_sales_toggle_authorized(
        contract_id: iota::object::ID,
        target_state: bool,
        notarization_id: iota::object::ID,
    ) {
        iota::event::emit(SalesToggleAuthorized {
            contract_id,
            target_state,
            notarization_id,
        });
    }

    public(package) fun emit_sales_toggle_consumed(
        contract_id: iota::object::ID,
        new_state: bool,
    ) {
        iota::event::emit(SalesToggleConsumed { contract_id, new_state });
    }

    // ==================== LTC1 Emitters ====================

    public(package) fun emit_contract_created(
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

    public(package) fun emit_token_purchased(
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

    public(package) fun emit_revenue_deposited(
        package_id: iota::object::ID,
        amount: u64
    ) {
        iota::event::emit(RevenueDeposited {
            package_id,
            amount
        });
    }

    public(package) fun emit_funding_withdrawn(
        package_id: iota::object::ID,
        amount: u64,
        recipient: address,
    ) {
        iota::event::emit(FundingWithdrawn {
            package_id,
            amount,
            recipient,
        });
    }

    public(package) fun emit_revenue_claimed_owner(
        package_id: iota::object::ID,
        amount: u64,
        owner: address,
    ) {
        iota::event::emit(RevenueClaimedOwner {
            package_id,
            amount,
            owner,
        });
    }

    public(package) fun emit_revenue_claimed_investor(
        package_id: iota::object::ID,
        token_id: iota::object::ID,
        amount: u64,
        investor: address,
    ) {
        iota::event::emit(RevenueClaimedInvestor {
            package_id,
            token_id,
            amount,
            investor,
        });
    }

    public(package) fun emit_bond_transferred(
        bond_id: iota::object::ID,
        package_id: iota::object::ID,
        new_owner: address,
    ) {
        iota::event::emit(BondTransferred {
            bond_id,
            package_id,
            new_owner,
        });
    }

    public(package) fun emit_owner_did_updated(
        package_id: iota::object::ID,
        owner_did: option::Option<address>,
    ) {
        iota::event::emit(OwnerDidUpdated {
            package_id,
            owner_did,
        });
    }

    public(package) fun emit_identity_approved(
        identity_id: iota::object::ID,
        role: u8,
    ) {
        iota::event::emit(IdentityApproved {
            identity_id,
            role,
        });
    }

    public(package) fun emit_identity_revoked(
        identity_id: iota::object::ID,
    ) {
        iota::event::emit(IdentityRevoked {
            identity_id,
        });
    }

    public(package) fun emit_sales_toggled(
        package_id: iota::object::ID,
        new_state: bool,
    ) {
        iota::event::emit(SalesToggled {
            package_id,
            new_state,
        });
    }

    // ==================== Fractional Emitters ====================

    public(package) fun emit_vault_created(
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

    public(package) fun emit_fraction_redeemed(
        vault_id: iota::object::ID,
        amount: u64,
        redeemer: address,
    ) {
        iota::event::emit(FractionRedeemed {
            vault_id,
            amount,
            redeemer,
        });
    }

    public(package) fun emit_fraction_merged_back(
        vault_id: iota::object::ID,
        token_id: iota::object::ID,
        amount: u64,
    ) {
        iota::event::emit(FractionMergedBack {
            vault_id,
            token_id,
            amount,
        });
    }

    public(package) fun emit_vault_empty(
        vault_id: iota::object::ID,
        fraction_type: std::ascii::String,
    ) {
        iota::event::emit(VaultEmpty {
            vault_id,
            fraction_type
        });
    }

    public(package) fun emit_vault_destroyed(
        vault_id: iota::object::ID,
    ) {
        iota::event::emit(VaultDestroyed { vault_id });
    }
}
