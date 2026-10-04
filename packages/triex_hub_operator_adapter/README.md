# triex_hub_operator_adapter

The adapter `triex::fee_policy` pins with `set_operator_adapter`. It lets the
owner of a storage unit choose and change the address that receives the hub
operator share of fees on every multicoin pool trading that storage unit's
warehouse-receipt collection.

Triex stores one payout address per `collection_id`. Only this package can write
it, and it writes only for the holder of the storage unit's own
`OwnerCap<StorageUnit>` (the cap `StorageUnit::owner_cap_id` records), against
the warehouse_receipts `VaultConfig` for that collection.

## Entry points

| Function | When |
|---|---|
| `register_operator_for_new_vault(policy, &PendingVault, &StorageUnit, &OwnerCap, beneficiary)` | First-time storage unit setup, inside the same PTB as `receipt::new_vault` … `receipt::share_vault` |
| `register_operator(policy, &VaultConfig, &StorageUnit, &OwnerCap, beneficiary)` | A vault initialized earlier, or re-registering after an admin destroy |
| `update_operator(policy, &VaultConfig, &StorageUnit, &OwnerCap, beneficiary)` | Re-point an existing payout address (new owner, new partner, OU treasury) |

`beneficiary` is any address: the owner, a partner, or an armature
`TreasuryVault` (its permissionless `treasury_vault::claim_coin` sweeps coins
sent to its address).

Claiming is unchanged and permissionless:
`triex::multicoin_pool::claim_operator_share` pays the registered address and the
treasury, per pool.

### First-time setup PTB (`/permissions`)

```
(cap, receipt)  = world::character::borrow_owner_cap<StorageUnit>(character, capTicket)
pending         = warehouse_receipts::receipt::new_vault(storageUnit, cap)
                  world::storage_unit::authorize_extension<VaultAuth>(storageUnit, cap)
                  world::storage_unit::freeze_extension_config(storageUnit, cap)
                  hub_adapter::register_operator_for_new_vault(feePolicy, pending, storageUnit, cap, sender)
                  warehouse_receipts::receipt::share_vault(pending)
                  world::character::return_owner_cap<StorageUnit>(character, cap, receipt)
```

For a storage unit whose vault already exists, replace `new_vault` /
`register_operator_for_new_vault` / `share_vault` with
`register_operator(feePolicy, vaultConfig, storageUnit, cap, sender)`, and skip it
when `fee_policy::operator_beneficiary(collection_id)` is already set (it aborts
with `EAlreadyRegistered`).

### Selling a storage unit

The payout address does not follow the cap. The seller hands over in one PTB:
borrow the cap → `update_operator(…, buyerAddress)` →
`world::access::transfer_owner_cap_with_receipt`. Any backlog still unclaimed
at that point pays the buyer, so the seller claims every pool first. A storage
unit can carry several collections (one per `new_vault`); each is rotated
separately.

## Events

Per `collection_id`, the full lifecycle is on the event stream:

| Event | Package | Emitted by |
|---|---|---|
| `OperatorAdapterAuthorized { adapter }` | triex | admin pin / clear |
| `OperatorBeneficiaryRegistered { collection_id, beneficiary }` | triex | registration |
| `HubOperatorRegistered { collection_id, storage_unit_id, vault_config_id, owner_cap_id, beneficiary, registered_by }` | adapter | registration |
| `OperatorBeneficiaryChanged { collection_id, previous, beneficiary }` | triex (new in the upgrade) | rotation |
| `HubOperatorChanged { …, owner_cap_id, previous, beneficiary, changed_by }` | adapter | rotation |
| `OperatorBeneficiaryDestroyed { collection_id }` | triex | admin destroy |
| `OperatorShareClaimed { pool_id, collection_id, beneficiary, amount, timestamp }` | triex | each payout |

In the first-time setup PTB, `warehouse_receipts::receipt::VaultInitializedEvent`
(emitted by `new_vault`) precedes the registration events.

`OperatorBeneficiaryChanged` is introduced by the triex upgrade, so its type tag
carries the **upgraded** package id, not triex's original id. Indexers that
filter events by package must subscribe to both.

## Abort codes

| Code | Name | Meaning |
|---|---|---|
| 0 | `ENotStorageUnitOwner` | The cap is not the storage unit's recorded owner cap |
| 1 | `EAlreadyRegistered` | The collection already has a payout address; use `update_operator` |
| 2 | `EStorageUnitMismatch` | The `StorageUnit` is not the one the `VaultConfig` belongs to |

From `triex::fee_policy`:

| Code | Name | Meaning |
|---|---|---|
| 9 | `ENoAuthorizedAdapter` | The admin has not pinned the adapter, or has cleared it |
| 12 | `EOperatorBeneficiaryNotRegistered` | `update_operator` with nothing to rotate; use `register_operator` |
| 13 | `EOperatorBeneficiaryUnchanged` | `update_operator` to the current payout address |

## Deploy

Per `FeePolicy` (the pin is permanent on it):

1. Bump the `warehouse_receipts` git rev in Move.toml to the commit carrying the
   upgraded `Published.toml` (the package with `receipt::new_vault` /
   `PendingVault`, loash-industries/warehouse-receipts#1).
   Check that `triex`, `warehouse_receipts`, `world` and `multicoin` resolve to the
   on-chain packages the deployment uses.
2. `sui client publish --build-env testnet_stillness`.
3. **Make it immutable**: `sui client call --package 0x2 --module package
   --function make_immutable --args <adapter UpgradeCap>`. The pin survives
   upgrades, so a live UpgradeCap could add a function that mints
   `HubAdapterWitness` and redirects every collection's revenue.
4. Check `fee_policy::pinned_operator_adapter` is `none`, then the admin calls
   `fee_policy::set_operator_adapter<<ADAPTER>::hub_adapter::HubAdapterWitness>(policy, adminCap)`.

When a cycle fresh-publishes triex (new `FeePolicy`), republish this package
against it and repeat. Within a cycle triex is upgraded in place, and this
package stays as published. The pin only accepts the world and
warehouse_receipts types this package was linked against, so fresh-publishing
either of those without a fresh triex leaves new storage units unable to
register.

## Trust and limits

Only the holder of a storage unit's canonical cap can register or re-point its
collections, *as a user*. Also able to re-point a hub, and trusted accordingly:

- this package's `UpgradeCap` — hence `make_immutable` before pinning;
- world AdminACL sponsors — `character::update_address` lets a sponsor act as
  any character's wallet for a transaction; a sponsoring service that co-signs
  arbitrary user PTBs extends that to its users;
- the warehouse_receipts and world `UpgradeCap`s — they guard the
  `VaultConfig.storage_unit_id` and `StorageUnit.owner_cap_id` bindings.

Once world unanchors a storage unit or deletes its cap, its collections' payout
addresses are frozen at their last value; an admin destroy after that cannot
be undone by re-registration.

Every adapter write takes `&mut FeePolicy`, which every trade reads. Rotation
and vault creation are not rate-limited, so heavy rotation traffic contends
with trading on that object.

## Tests

`sui move test` runs unit tests (`hub_adapter_tests`) and end-to-end tests
(`hub_operator_e2e_tests`: warehouse receipts traded on a real multicoin pool,
fees accrued and claimed through setup, after-the-fact registration, rotation,
sale and admin destroy). `sui move test --coverage` reports 100% for
`hub_adapter`.
