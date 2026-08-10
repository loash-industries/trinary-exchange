// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Registry holds all created pools.
module triexbook::registry;

use std::type_name::{Self, TypeName};
use sui::{
    bag::{Self, Bag},
    coin,
    dynamic_field,
    table::{Self, Table},
    vec_set::{Self, VecSet},
    versioned::{Self, Versioned}
};
use triexbook::constants;

// === Errors ===
const EPoolAlreadyExists: u64 = 1;
const EPoolDoesNotExist: u64 = 2;
const EPackageVersionNotEnabled: u64 = 3;
const EVersionNotEnabled: u64 = 4;
const EVersionAlreadyEnabled: u64 = 5;
const ECannotDisableCurrentVersion: u64 = 6;
const ECoinAlreadyWhitelisted: u64 = 7;
const ECoinNotWhitelisted: u64 = 8;
const EMaxBalanceManagersReached: u64 = 9;
const EQuoteNotApproved: u64 = 10;
const EQuoteAlreadyApproved: u64 = 11;
const EMulticoinPoolAlreadyExists: u64 = 13;
const EMulticoinPoolDoesNotExist: u64 = 14;
const EQuoteInsufficientDecimals: u64 = 15;

const MIN_QUOTE_DECIMALS: u8 = 3;

// === Structs ===
/// TriexbookAdminCap is used to call admin functions.
public struct TriexbookAdminCap has key, store {
    id: UID,
}

public struct Registry has key {
    id: UID,
    inner: Versioned,
}

public struct RegistryInner has store {
    allowed_versions: VecSet<u64>,
    pools: Bag,
    treasury_address: address,
}

public struct PoolKey has copy, drop, store {
    base: TypeName,
    quote: TypeName,
}

public struct StableCoinKey has copy, drop, store {}
public struct BalanceManagerKey has copy, drop, store {}
public struct ApprovedQuoteKey has copy, drop, store {}
public struct MultiCoinPoolsKey has copy, drop, store {}

/// Key for looking up MultiCoin pools by (collection_id, asset_id, quote_type)
public struct MultiCoinPoolKey has copy, drop, store {
    collection_id: ID,
    asset_id: u64,
    quote: TypeName,
}

fun init(ctx: &mut TxContext) {
    let registry_inner = RegistryInner {
        allowed_versions: vec_set::singleton(constants::current_version()),
        pools: bag::new(ctx),
        treasury_address: ctx.sender(),
    };

    let registry = Registry {
        id: object::new(ctx),
        inner: versioned::create(
            constants::current_version(),
            registry_inner,
            ctx,
        ),
    };
    transfer::share_object(registry);

    let admin = TriexbookAdminCap { id: object::new(ctx) };
    transfer::public_transfer(admin, ctx.sender());
}

// === Public Admin Functions ===
/// Sets the treasury address where the pool creation fees are sent
/// By default, the treasury address is the publisher of the triexbook package
public fun set_treasury_address(
    self: &mut Registry,
    treasury_address: address,
    _cap: &TriexbookAdminCap,
) {
    let self = self.load_inner_mut();
    self.treasury_address = treasury_address;
}

/// Enables a package version
/// Only Admin can enable a package version
/// This function does not have version restrictions
public fun enable_version(self: &mut Registry, version: u64, _cap: &TriexbookAdminCap) {
    let self: &mut RegistryInner = self.inner.load_value_mut();
    assert!(!self.allowed_versions.contains(&version), EVersionAlreadyEnabled);
    self.allowed_versions.insert(version);
}

/// Disables a package version
/// Only Admin can disable a package version
/// This function does not have version restrictions
public fun disable_version(self: &mut Registry, version: u64, _cap: &TriexbookAdminCap) {
    let self: &mut RegistryInner = self.inner.load_value_mut();
    assert!(version != constants::current_version(), ECannotDisableCurrentVersion);
    assert!(self.allowed_versions.contains(&version), EVersionNotEnabled);
    self.allowed_versions.remove(&version);
}

/// Adds a stablecoin to the whitelist
/// Only Admin can add stablecoin
public fun add_stablecoin<StableCoin>(self: &mut Registry, _cap: &TriexbookAdminCap) {
    let _: &mut RegistryInner = self.load_inner_mut();
    let stable_type = type_name::with_defining_ids<StableCoin>();
    if (
        !dynamic_field::exists_(
            &self.id,
            StableCoinKey {},
        )
    ) {
        dynamic_field::add(
            &mut self.id,
            StableCoinKey {},
            vec_set::singleton(stable_type),
        );
    } else {
        let stable_coins: &mut VecSet<TypeName> = dynamic_field::borrow_mut(
            &mut self.id,
            StableCoinKey {},
        );
        assert!(!stable_coins.contains(&stable_type), ECoinAlreadyWhitelisted);
        stable_coins.insert(stable_type);
    };
}

/// Removes a stablecoin from the whitelist
/// Only Admin can remove stablecoin
public fun remove_stablecoin<StableCoin>(self: &mut Registry, _cap: &TriexbookAdminCap) {
    let _: &mut RegistryInner = self.load_inner_mut();
    let stable_type = type_name::with_defining_ids<StableCoin>();
    assert!(
        dynamic_field::exists_(
            &self.id,
            StableCoinKey {},
        ),
        ECoinNotWhitelisted,
    );
    let stable_coins: &mut VecSet<TypeName> = dynamic_field::borrow_mut(
        &mut self.id,
        StableCoinKey {},
    );
    assert!(stable_coins.contains(&stable_type), ECoinNotWhitelisted);
    stable_coins.remove(&stable_type);
}

/// Adds a quote currency to the approved list.
/// Rejects tokens with fewer than MIN_QUOTE_DECIMALS decimals to ensure fee
/// precision is meaningful across all supported quote currencies.
/// Only Admin can add approved quote currency.
public fun add_approved_quote<QuoteCoin>(
    self: &mut Registry,
    metadata: &coin::CoinMetadata<QuoteCoin>,
    _cap: &TriexbookAdminCap,
) {
    assert!(coin::get_decimals(metadata) >= MIN_QUOTE_DECIMALS, EQuoteInsufficientDecimals);
    self.add_approved_quote_internal<QuoteCoin>();
}

/// Adds a quote currency without the decimal check. For test scenarios where
/// the test token is a plain struct with no CoinMetadata, or to grandfather in
/// low-decimal tokens under admin discretion.
#[test_only]
public fun add_approved_quote_unchecked<QuoteCoin>(self: &mut Registry, _cap: &TriexbookAdminCap) {
    self.add_approved_quote_internal<QuoteCoin>();
}

fun add_approved_quote_internal<QuoteCoin>(self: &mut Registry) {
    let _: &mut RegistryInner = self.load_inner_mut();
    let quote_type = type_name::with_defining_ids<QuoteCoin>();
    if (
        !dynamic_field::exists_(
            &self.id,
            ApprovedQuoteKey {},
        )
    ) {
        dynamic_field::add(
            &mut self.id,
            ApprovedQuoteKey {},
            vec_set::singleton(quote_type),
        );
    } else {
        let approved_quotes: &mut VecSet<TypeName> = dynamic_field::borrow_mut(
            &mut self.id,
            ApprovedQuoteKey {},
        );
        assert!(!approved_quotes.contains(&quote_type), EQuoteAlreadyApproved);
        approved_quotes.insert(quote_type);
    };
}

/// Removes a quote currency from the approved list
/// Only Admin can remove approved quote currency
public fun remove_approved_quote<QuoteCoin>(self: &mut Registry, _cap: &TriexbookAdminCap) {
    let _: &mut RegistryInner = self.load_inner_mut();
    let quote_type = type_name::with_defining_ids<QuoteCoin>();
    assert!(
        dynamic_field::exists_(
            &self.id,
            ApprovedQuoteKey {},
        ),
        EQuoteNotApproved,
    );
    let approved_quotes: &mut VecSet<TypeName> = dynamic_field::borrow_mut(
        &mut self.id,
        ApprovedQuoteKey {},
    );
    assert!(approved_quotes.contains(&quote_type), EQuoteNotApproved);
    approved_quotes.remove(&quote_type);
}

/// Adds the BalanceManagerKey dynamic field to the registry
public fun init_balance_manager_map(
    self: &mut Registry,
    _cap: &TriexbookAdminCap,
    ctx: &mut TxContext,
) {
    let _: &mut RegistryInner = self.load_inner_mut();
    if (
        !dynamic_field::exists_(
            &self.id,
            BalanceManagerKey {},
        )
    ) {
        dynamic_field::add(
            &mut self.id,
            BalanceManagerKey {},
            table::new<address, VecSet<ID>>(ctx),
        );
    };
}

/// Get the balance manager IDs for a given owner
public fun get_balance_manager_ids(self: &Registry, owner: address): VecSet<ID> {
    let balance_manager_map: &Table<address, VecSet<ID>> = dynamic_field::borrow(
        &self.id,
        BalanceManagerKey {},
    );
    if (balance_manager_map.contains(owner)) {
        *balance_manager_map.borrow<address, VecSet<ID>>(owner)
    } else {
        vec_set::empty()
    }
}

/// Returns whether the given coin is whitelisted
public fun is_stablecoin(self: &Registry, stable_type: TypeName): bool {
    let _: &RegistryInner = self.load_inner();
    if (
        !dynamic_field::exists_(
            &self.id,
            StableCoinKey {},
        )
    ) {
        false
    } else {
        let stable_coins: &VecSet<TypeName> = dynamic_field::borrow(
            &self.id,
            StableCoinKey {},
        );

        stable_coins.contains(&stable_type)
    }
}

/// Returns whether the given quote currency is approved for pool creation
public fun is_quote_approved(self: &Registry, quote_type: TypeName): bool {
    let _: &RegistryInner = self.load_inner();
    if (
        !dynamic_field::exists_(
            &self.id,
            ApprovedQuoteKey {},
        )
    ) {
        false
    } else {
        let approved_quotes: &VecSet<TypeName> = dynamic_field::borrow(
            &self.id,
            ApprovedQuoteKey {},
        );

        approved_quotes.contains(&quote_type)
    }
}

// === Public-Package Functions ===
public(package) fun load_inner_mut(self: &mut Registry): &mut RegistryInner {
    let inner: &mut RegistryInner = self.inner.load_value_mut();
    let package_version = constants::current_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionNotEnabled);

    inner
}

/// Register a new pool in the registry.
/// Asserts if (Base, Quote) pool already exists or
/// (Quote, Base) pool already exists.
public(package) fun register_pool<BaseAsset, QuoteAsset>(self: &mut Registry, pool_id: ID) {
    let self = self.load_inner_mut();
    let key = PoolKey {
        base: type_name::with_defining_ids<QuoteAsset>(),
        quote: type_name::with_defining_ids<BaseAsset>(),
    };
    assert!(!self.pools.contains(key), EPoolAlreadyExists);

    let key = PoolKey {
        base: type_name::with_defining_ids<BaseAsset>(),
        quote: type_name::with_defining_ids<QuoteAsset>(),
    };
    assert!(!self.pools.contains(key), EPoolAlreadyExists);

    self.pools.add(key, pool_id);
}

/// Register a new MultiCoin pool in the registry.
/// Asserts if pool with same (collection_id, asset_id, QuoteAsset) already exists.
/// Pools from any collection are accepted — each (collection_id, asset_id, quote) triple is unique.
public(package) fun register_multicoin_pool<QuoteAsset>(
    self: &mut Registry,
    collection_id: ID,
    asset_id: u64,
    pool_id: ID,
    ctx: &mut TxContext,
) {
    let _inner = self.load_inner_mut();

    let key = MultiCoinPoolKey {
        collection_id,
        asset_id,
        quote: type_name::with_defining_ids<QuoteAsset>(),
    };

    // Initialize multicoin pools bag if not exists
    if (!dynamic_field::exists_(&self.id, MultiCoinPoolsKey {})) {
        dynamic_field::add(&mut self.id, MultiCoinPoolsKey {}, bag::new(ctx));
    };

    let pools: &mut Bag = dynamic_field::borrow_mut(&mut self.id, MultiCoinPoolsKey {});
    assert!(!pools.contains(key), EMulticoinPoolAlreadyExists);
    pools.add(key, pool_id);
}

/// Unregister a MultiCoin pool from the registry (admin only).
public(package) fun unregister_multicoin_pool<QuoteAsset>(
    self: &mut Registry,
    collection_id: ID,
    asset_id: u64,
) {
    let _inner = self.load_inner_mut();
    let key = MultiCoinPoolKey {
        collection_id,
        asset_id,
        quote: type_name::with_defining_ids<QuoteAsset>(),
    };

    assert!(dynamic_field::exists_(&self.id, MultiCoinPoolsKey {}), EMulticoinPoolDoesNotExist);
    let pools: &mut Bag = dynamic_field::borrow_mut(&mut self.id, MultiCoinPoolsKey {});
    assert!(pools.contains(key), EMulticoinPoolDoesNotExist);
    pools.remove<MultiCoinPoolKey, ID>(key);
}

/// Only admin can call this function
public(package) fun unregister_pool<BaseAsset, QuoteAsset>(self: &mut Registry) {
    let self = self.load_inner_mut();
    let key = PoolKey {
        base: type_name::with_defining_ids<BaseAsset>(),
        quote: type_name::with_defining_ids<QuoteAsset>(),
    };
    assert!(self.pools.contains(key), EPoolDoesNotExist);
    self.pools.remove<PoolKey, ID>(key);
}

public(package) fun load_inner(self: &Registry): &RegistryInner {
    let inner: &RegistryInner = self.inner.load_value();
    let package_version = constants::current_version();
    assert!(inner.allowed_versions.contains(&package_version), EPackageVersionNotEnabled);

    inner
}

/// Adds a balance_manager to the registry
public(package) fun add_balance_manager(self: &mut Registry, owner: address, manager_id: ID) {
    let _: &mut RegistryInner = self.load_inner_mut();
    let balance_manager_map: &mut Table<address, VecSet<ID>> = dynamic_field::borrow_mut(
        &mut self.id,
        BalanceManagerKey {},
    );
    if (!balance_manager_map.contains(owner)) {
        balance_manager_map.add(owner, vec_set::empty());
    };
    let balance_manager_ids = balance_manager_map.borrow_mut(owner);
    if (!balance_manager_ids.contains(&manager_id)) {
        balance_manager_ids.insert(manager_id);
    };
    assert!(
        balance_manager_ids.length() <= constants::max_balance_managers(),
        EMaxBalanceManagersReached,
    );
}

/// Get the pool id for the given base and quote assets.
public(package) fun get_pool_id<BaseAsset, QuoteAsset>(self: &Registry): ID {
    let self = self.load_inner();
    let key = PoolKey {
        base: type_name::with_defining_ids<BaseAsset>(),
        quote: type_name::with_defining_ids<QuoteAsset>(),
    };
    assert!(self.pools.contains(key), EPoolDoesNotExist);

    *self.pools.borrow<PoolKey, ID>(key)
}

/// Get the MultiCoin pool ID for the given collection, asset, and quote type.
public(package) fun get_multicoin_pool_id<QuoteAsset>(
    self: &Registry,
    collection_id: ID,
    asset_id: u64,
): ID {
    let _inner = self.load_inner();
    let key = MultiCoinPoolKey {
        collection_id,
        asset_id,
        quote: type_name::with_defining_ids<QuoteAsset>(),
    };

    assert!(dynamic_field::exists_(&self.id, MultiCoinPoolsKey {}), EMulticoinPoolDoesNotExist);
    let pools: &Bag = dynamic_field::borrow(&self.id, MultiCoinPoolsKey {});
    assert!(pools.contains(key), EMulticoinPoolDoesNotExist);

    *pools.borrow<MultiCoinPoolKey, ID>(key)
}

/// Check if a MultiCoin pool exists for the given collection, asset, and quote type.
public fun multicoin_pool_exists<QuoteAsset>(
    self: &Registry,
    collection_id: ID,
    asset_id: u64,
): bool {
    let _inner = self.load_inner();
    if (!dynamic_field::exists_(&self.id, MultiCoinPoolsKey {})) {
        return false
    };

    let key = MultiCoinPoolKey {
        collection_id,
        asset_id,
        quote: type_name::with_defining_ids<QuoteAsset>(),
    };
    let pools: &Bag = dynamic_field::borrow(&self.id, MultiCoinPoolsKey {});
    pools.contains(key)
}

/// Get the treasury address
public(package) fun treasury_address(self: &Registry): address {
    let self = self.load_inner();
    self.treasury_address
}

public(package) fun allowed_versions(self: &Registry): VecSet<u64> {
    let self = self.load_inner();

    self.allowed_versions
}

// === Test Functions ===
#[test_only]
public fun test_registry(ctx: &mut TxContext): ID {
    let registry_inner = RegistryInner {
        allowed_versions: vec_set::singleton(constants::current_version()),
        pools: bag::new(ctx),
        treasury_address: ctx.sender(),
    };
    let registry = Registry {
        id: object::new(ctx),
        inner: versioned::create(
            constants::current_version(),
            registry_inner,
            ctx,
        ),
    };
    let id = object::id(&registry);
    transfer::share_object(registry);

    id
}

#[test_only]
public fun get_admin_cap_for_testing(ctx: &mut TxContext): TriexbookAdminCap {
    TriexbookAdminCap { id: object::new(ctx) }
}
