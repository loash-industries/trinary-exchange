/// End-to-end: a real storage unit's warehouse receipts trade on a triex
/// multicoin pool, the trades recognize fee revenue, and the hub's share is
/// claimed to whoever the storage unit's owner registered — through first-time
/// setup, after-the-fact registration, delegation, a sale of the structure,
/// and an admin destroy.
///
/// The property under test throughout: the operator share only ever reaches
/// an address the storage unit's owner (at the time of the write) chose, and
/// the permissionless claim never pays its caller.
#[test_only]
module triex_hub_operator_adapter::hub_operator_e2e_tests {
    use multicoin::multicoin::Collection;
    use std::unit_test;
    use sui::{clock::Clock, coin::{Self, Coin}, event, test_scenario::{Self as ts, Scenario}};
    use triex::{
        constants,
        fee_policy::FeePolicy,
        multicoin_pool::{Self, MultiCoinPool},
        registry::{Self, Registry},
        trading_account::{Self, TradingAccount}
    };
    use triex::multicoin_vault::OperatorShareClaimed;
    use triex_hub_operator_adapter::test_world::{Self, HUB_USD, Site};
    use warehouse_receipts::{receipt, vault::VaultConfig};
    use world::{access::OwnerCap, character::Character, storage_unit::StorageUnit};

    const OWNER: address = @0xC;
    const PARTNER: address = @0xF00D;
    const BUYER: address = @0xE;
    // Trades and claims; never registered as anything.
    const SELLER: address = @0x5E11;
    const BIDDER: address = @0xB1D;
    const STRANGER: address = @0x5743;

    // The in-game item the receipts represent; it is also the pool's asset id.
    const ITEM_TYPE_ID: u64 = 88070;
    const ITEM_VOLUME: u64 = 50;
    const LOT: u64 = 1000;

    /// Multicoin books price in raw quote per raw base unit (no float
    /// scaling): one lot is 1_000 × 1_000 = 1 HUB_USD at six decimals.
    fun price(): u64 {
        1_000
    }

    // === Setup ===

    /// An online storage unit for `OWNER`, its pool, and a seller holding
    /// `lots` lots of receipts in a trading account, plus a funded bidder.
    /// `register_at_setup` runs the one-PTB first-time setup with `OWNER` as
    /// payee; otherwise the vault is initialized with nobody registered.
    ///
    /// Returns `(site, pool_id, seller_ta, bidder_ta)`.
    fun hub(sc: &mut Scenario, register_at_setup: bool, lots: u32): (Site, ID, ID, ID) {
        test_world::setup(sc);
        test_world::pin_adapter(sc);

        let mut site = test_world::create_site(sc, OWNER, 1, true);
        if (register_at_setup) {
            test_world::initialize_vault_and_register(sc, &mut site, OWNER);
        } else {
            test_world::initialize_vault(sc, &mut site);
        };

        let pool_id = create_pool(sc, &site);
        let seller_ta = stock_seller(sc, &site, lots * (LOT as u32));
        let bidder_ta = fund(sc, BIDDER, 1_000_000_000_000);
        (site, pool_id, seller_ta, bidder_ta)
    }

    fun create_pool(sc: &mut Scenario, site: &Site): ID {
        ts::next_tx(sc, test_world::admin());
        let mut reg = ts::take_shared<Registry>(sc);
        let policy = ts::take_shared<FeePolicy>(sc);
        let collection = ts::take_shared_by_id<Collection>(sc, site.collection());
        let cap = registry::get_admin_cap_for_testing(sc.ctx());
        let pool_id = multicoin_pool::create_pool_admin<HUB_USD>(
            &mut reg,
            &policy,
            &collection,
            ITEM_TYPE_ID,
            &cap,
            sc.ctx(),
        );
        unit_test::destroy(cap);
        ts::return_shared(collection);
        ts::return_shared(policy);
        ts::return_shared(reg);
        pool_id
    }

    /// The seller brings items on-chain at the storage unit, deposits them for
    /// warehouse receipts, and moves the receipts into a trading account
    /// alongside quote for taker fees.
    fun stock_seller(sc: &mut Scenario, site: &Site, quantity: u32): ID {
        let seller_character = test_world::create_character(sc, SELLER, 100);

        ts::next_tx(sc, SELLER);
        let mut character = ts::take_shared_by_id<Character>(sc, seller_character);
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(sc, site.storage_unit());
        let (cap, cap_receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&seller_character),
            sc.ctx(),
        );
        storage_unit.game_item_to_chain_inventory_test<Character>(
            &character,
            &cap,
            1_000_004_145_108,
            ITEM_TYPE_ID,
            ITEM_VOLUME,
            quantity,
            sc.ctx(),
        );
        character.return_owner_cap(cap, cap_receipt);
        ts::return_shared(storage_unit);
        ts::return_shared(character);

        ts::next_tx(sc, SELLER);
        let mut character = ts::take_shared_by_id<Character>(sc, seller_character);
        let mut storage_unit = ts::take_shared_by_id<StorageUnit>(sc, site.storage_unit());
        let config = ts::take_shared_by_id<VaultConfig>(sc, site.vault_config());
        let mut collection = ts::take_shared_by_id<Collection>(sc, site.collection());
        let (cap, cap_receipt) = character.borrow_owner_cap<Character>(
            ts::most_recent_receiving_ticket<OwnerCap<Character>>(&seller_character),
            sc.ctx(),
        );
        let receipts = receipt::deposit_for_receipt(
            &mut storage_unit,
            &character,
            &cap,
            &config,
            &mut collection,
            ITEM_TYPE_ID,
            quantity,
            sc.ctx(),
        );
        let mut ta = trading_account::new(sc.ctx());
        ta.deposit_multicoin(receipts, sc.ctx());
        // A taker pays its fee in quote, so the seller carries some.
        ta.deposit(coin::mint_for_testing<HUB_USD>(1_000_000_000_000, sc.ctx()), sc.ctx());
        let ta_id = object::id(&ta);
        transfer::public_share_object(ta);

        character.return_owner_cap(cap, cap_receipt);
        ts::return_shared(collection);
        ts::return_shared(config);
        ts::return_shared(storage_unit);
        ts::return_shared(character);
        ta_id
    }

    fun fund(sc: &mut Scenario, trader: address, amount: u64): ID {
        ts::next_tx(sc, trader);
        let mut ta = trading_account::new(sc.ctx());
        ta.deposit(coin::mint_for_testing<HUB_USD>(amount, sc.ctx()), sc.ctx());
        let id = object::id(&ta);
        transfer::public_share_object(ta);
        id
    }

    // === Trading and claiming ===

    /// The bidder rests a one-lot bid; the seller fills it. Returns the
    /// operator share the fill credited.
    fun trade_one_lot(sc: &mut Scenario, pool_id: ID, seller_ta: ID, bidder_ta: ID): u64 {
        let owed_before = operator_owed(sc, pool_id);
        place(sc, BIDDER, pool_id, bidder_ta, true);
        place(sc, SELLER, pool_id, seller_ta, false);
        let credited = operator_owed(sc, pool_id) - owed_before;
        assert!(credited > 0);
        credited
    }

    fun place(sc: &mut Scenario, trader: address, pool_id: ID, ta_id: ID, is_bid: bool) {
        ts::next_tx(sc, trader);
        let mut pool = ts::take_shared_by_id<MultiCoinPool<HUB_USD>>(sc, pool_id);
        let policy = ts::take_shared<FeePolicy>(sc);
        let clock = ts::take_shared<Clock>(sc);
        let mut ta = ts::take_shared_by_id<TradingAccount>(sc, ta_id);
        let proof = ta.generate_proof_as_owner(sc.ctx());
        pool.place_limit_order(
            &policy,
            &mut ta,
            &proof,
            constants::no_restriction(),
            constants::self_matching_allowed(),
            price(),
            LOT,
            is_bid,
            constants::max_u64(),
            &clock,
            sc.ctx(),
        );
        ts::return_shared(ta);
        ts::return_shared(clock);
        ts::return_shared(policy);
        ts::return_shared(pool);
    }

    fun operator_owed(sc: &mut Scenario, pool_id: ID): u64 {
        ts::next_tx(sc, test_world::admin());
        let pool = ts::take_shared_by_id<MultiCoinPool<HUB_USD>>(sc, pool_id);
        let owed = pool.operator_owed();
        ts::return_shared(pool);
        owed
    }

    /// The permissionless claim, run by `caller`. Returns `(hub, treasury)`.
    fun claim(sc: &mut Scenario, caller: address, pool_id: ID): (u64, u64) {
        ts::next_tx(sc, caller);
        let mut pool = ts::take_shared_by_id<MultiCoinPool<HUB_USD>>(sc, pool_id);
        let policy = ts::take_shared<FeePolicy>(sc);
        let reg = ts::take_shared<Registry>(sc);
        let clock = ts::take_shared<Clock>(sc);
        let (hub_paid, treasury_paid) = pool.claim_operator_share(&policy, &reg, &clock, sc.ctx());
        assert!(pool.operator_owed() == 0);
        ts::return_shared(clock);
        ts::return_shared(reg);
        ts::return_shared(policy);
        ts::return_shared(pool);
        (hub_paid, treasury_paid)
    }

    /// The single coin of `HUB_USD` the previous transaction sent `who`.
    fun received(sc: &mut Scenario, who: address): u64 {
        ts::next_tx(sc, who);
        let paid = ts::take_from_address<Coin<HUB_USD>>(sc, who);
        let value = paid.value();
        unit_test::destroy(paid);
        value
    }

    fun receives_nothing(sc: &mut Scenario, who: address) {
        ts::next_tx(sc, who);
        assert!(!ts::has_most_recent_for_address<Coin<HUB_USD>>(who));
    }

    // === Tests ===

    /// The happy path: one-PTB first-time setup registers the owner, a trade
    /// accrues the share, and a stranger's claim pays the owner and the
    /// treasury — never the stranger.
    #[test]
    fun first_time_setup_to_payout() {
        let mut sc = ts::begin(test_world::admin());
        let (_site, pool_id, seller_ta, bidder_ta) = hub(&mut sc, true, 1);

        let share = trade_one_lot(&mut sc, pool_id, seller_ta, bidder_ta);
        let (hub_paid, treasury_paid) = claim(&mut sc, STRANGER, pool_id);
        assert!(hub_paid == share);
        assert!(treasury_paid > 0);

        let claims = event::events_by_type<OperatorShareClaimed>();
        assert!(claims.length() == 1);

        assert!(received(&mut sc, OWNER) == share);
        receives_nothing(&mut sc, STRANGER);
        assert!(received(&mut sc, test_world::treasury()) == treasury_paid);
        ts::end(sc);
    }

    /// With nobody registered the share accrues but cannot be paid — the claim
    /// aborts rather than sending it anywhere.
    #[test, expected_failure(abort_code = multicoin_pool::ENoOperatorBeneficiary)]
    fun claiming_before_registration_aborts() {
        let mut sc = ts::begin(test_world::admin());
        let (_site, pool_id, seller_ta, bidder_ta) = hub(&mut sc, false, 1);

        trade_one_lot(&mut sc, pool_id, seller_ta, bidder_ta);
        claim(&mut sc, STRANGER, pool_id);
        ts::end(sc);
    }

    /// After-the-fact registration: an owner who initialized before the
    /// adapter existed registers later, naming a partner, and the partner is
    /// paid everything accrued in the meantime.
    #[test]
    fun after_the_fact_registration_releases_the_backlog() {
        let mut sc = ts::begin(test_world::admin());
        let (site, pool_id, seller_ta, bidder_ta) = hub(&mut sc, false, 2);

        let first = trade_one_lot(&mut sc, pool_id, seller_ta, bidder_ta);
        let second = trade_one_lot(&mut sc, pool_id, seller_ta, bidder_ta);

        test_world::register(&mut sc, OWNER, site.character(), &site, PARTNER);
        let (hub_paid, _) = claim(&mut sc, STRANGER, pool_id);
        assert!(hub_paid == first + second);
        assert!(received(&mut sc, PARTNER) == first + second);
        receives_nothing(&mut sc, OWNER);
        ts::end(sc);
    }

    /// The owner delegates, then re-points: each claim pays whoever is the
    /// payee at claim time.
    #[test]
    fun rotation_redirects_subsequent_claims() {
        let mut sc = ts::begin(test_world::admin());
        let (site, pool_id, seller_ta, bidder_ta) = hub(&mut sc, true, 2);

        let first = trade_one_lot(&mut sc, pool_id, seller_ta, bidder_ta);
        claim(&mut sc, STRANGER, pool_id);
        assert!(received(&mut sc, OWNER) == first);

        test_world::update(&mut sc, OWNER, site.character(), &site, PARTNER);
        let second = trade_one_lot(&mut sc, pool_id, seller_ta, bidder_ta);
        claim(&mut sc, STRANGER, pool_id);
        assert!(received(&mut sc, PARTNER) == second);
        receives_nothing(&mut sc, OWNER);
        ts::end(sc);
    }

    /// A sale: the seller claims what accrued on their watch, hands over the
    /// cap, and the buyer re-points the payee. Revenue after the sale goes to
    /// the buyer; the seller cannot take it back.
    #[test]
    fun a_sale_moves_future_revenue_to_the_buyer() {
        let mut sc = ts::begin(test_world::admin());
        let (mut site, pool_id, seller_ta, bidder_ta) = hub(&mut sc, true, 2);

        let before_sale = trade_one_lot(&mut sc, pool_id, seller_ta, bidder_ta);
        claim(&mut sc, OWNER, pool_id);
        assert!(received(&mut sc, OWNER) == before_sale);

        let buyer_character = test_world::create_character(&mut sc, BUYER, 50);
        test_world::transfer_storage_unit(&mut sc, &mut site, BUYER, buyer_character);
        test_world::update(&mut sc, BUYER, buyer_character, &site, BUYER);

        let after_sale = trade_one_lot(&mut sc, pool_id, seller_ta, bidder_ta);
        claim(&mut sc, OWNER, pool_id);
        assert!(received(&mut sc, BUYER) == after_sale);
        receives_nothing(&mut sc, OWNER);
        ts::end(sc);
    }

    /// The documented settlement edge: an unclaimed backlog follows the payee
    /// at claim time, so a buyer who re-points before anyone claims receives
    /// what accrued before the sale. Sellers claim first.
    #[test]
    fun an_unclaimed_backlog_pays_the_payee_at_claim_time() {
        let mut sc = ts::begin(test_world::admin());
        let (mut site, pool_id, seller_ta, bidder_ta) = hub(&mut sc, true, 1);

        let before_sale = trade_one_lot(&mut sc, pool_id, seller_ta, bidder_ta);

        let buyer_character = test_world::create_character(&mut sc, BUYER, 50);
        test_world::transfer_storage_unit(&mut sc, &mut site, BUYER, buyer_character);
        test_world::update(&mut sc, BUYER, buyer_character, &site, BUYER);

        claim(&mut sc, STRANGER, pool_id);
        assert!(received(&mut sc, BUYER) == before_sale);
        receives_nothing(&mut sc, OWNER);
        ts::end(sc);
    }

    /// An admin destroy halts payouts — the share stays encumbered, claimable
    /// by no one — until the owner registers again, which releases all of it.
    #[test]
    fun an_admin_destroy_encumbers_until_the_owner_reregisters() {
        let mut sc = ts::begin(test_world::admin());
        let (site, pool_id, seller_ta, bidder_ta) = hub(&mut sc, true, 1);

        let share = trade_one_lot(&mut sc, pool_id, seller_ta, bidder_ta);
        test_world::destroy_beneficiary(&mut sc, site.collection());
        assert!(operator_owed(&mut sc, pool_id) == share);

        test_world::register(&mut sc, OWNER, site.character(), &site, PARTNER);
        claim(&mut sc, STRANGER, pool_id);
        assert!(received(&mut sc, PARTNER) == share);
        ts::end(sc);
    }

    #[test, expected_failure(abort_code = multicoin_pool::ENoOperatorBeneficiary)]
    fun claiming_after_an_admin_destroy_aborts() {
        let mut sc = ts::begin(test_world::admin());
        let (site, pool_id, seller_ta, bidder_ta) = hub(&mut sc, true, 1);

        trade_one_lot(&mut sc, pool_id, seller_ta, bidder_ta);
        test_world::destroy_beneficiary(&mut sc, site.collection());
        claim(&mut sc, OWNER, pool_id);
        ts::end(sc);
    }
}
