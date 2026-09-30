/// This module defines the OrderPage struct and its methods to iterate over orders in a pool.
///
/// Coin-pool fork of the former `triex::order_query`, which was coin-only to
/// begin with (multicoin pools answer order queries inline in
/// `triex::multicoin_pool`). Pagination walks `BigVector` slices by key, so
/// seeking to an anchor is O(log n) rather than the linear scan the vector book
/// needed.
module triex::coin_order_query {
    use triex::{coin_order::Order, pool::Pool};

    /// === Structs ===
    public struct OrderPage has drop {
        orders: vector<Order>,
        has_next_page: bool,
    }

    /// === Public Functions ===
    /// Iterate orders in book priority order (best price first).
    ///
    /// Bids are keyed ascending by price and walked down from the top of the book;
    /// asks are keyed ascending and walked up from the bottom. Both therefore yield
    /// price-time priority.
    ///
    /// `start_order_id` (if provided) acts as an **exclusive**, *positional* anchor:
    /// iteration resumes at the first live order strictly past it in book order, so
    /// paging with the last id of the previous page never repeats it.
    ///
    /// The anchor does not have to name a live order. `slice_before` /
    /// `slice_following` seek by key, so an id that has since been filled or
    /// cancelled resolves to the position it *would* have occupied and the page
    /// continues from its neighbour. That is what a paginator wants — a cursor
    /// stays usable when the order under it leaves the book — but it does mean a
    /// stale cursor is served silently rather than reported. Callers that need to
    /// detect staleness must track it themselves.
    ///
    /// An anchor outside the side's key range is the one case that yields an empty
    /// page: there is no position past it to resume from. Unlike the vector
    /// implementation, no anchor ever restarts from the top of the book.
    ///
    /// The walk runs on `coin_book::Cursor`, which spans the inline top-of-book
    /// buffer and the `BigVector` behind it as one sequence, so a page that starts at
    /// the best price reads no dynamic field until it runs past the buffer.
    ///
    /// `end_order_id` (if provided) acts as a hard stop when encountered, and the
    /// order it names is not included.
    public fun iter_orders<BaseAsset, QuoteAsset>(
        self: &Pool<BaseAsset, QuoteAsset>,
        start_order_id: Option<u128>,
        end_order_id: Option<u128>,
        min_expire_timestamp: Option<u64>,
        limit: u64,
        bids: bool,
    ): OrderPage {
        let book = self.load_inner().book();
        if (book.side_is_empty(bids) || limit == 0) {
            return OrderPage { orders: vector[], has_next_page: false }
        };

        // Defaults sit just outside each side's key range, so an absent anchor
        // seeds at the best price: bids walk down from above every bid key, asks
        // walk up from below every ask key.
        let bid_max_order_id = 1u128 << 127;
        let ask_min_order_id = 1u128 << 127;
        let start = start_order_id.get_with_default({
            if (bids) bid_max_order_id else ask_min_order_id
        });
        let end = end_order_id.get_with_default(0);
        let min_expire = min_expire_timestamp.get_with_default(0);

        // Exclusive on both sides: `cursor_after` lands on the first order strictly
        // worse than the anchor.
        let mut cur = book.cursor_after(bids, start);

        let mut orders = vector[];
        let mut stopped_by_end = false;

        while (!cur.cursor_is_null() && orders.length() < limit) {
            let order = book.cursor_borrow(bids, &cur);

            if (end != 0 && order.order_id() == end) {
                stopped_by_end = true;
                break
            };

            if (order.expire_timestamp() >= min_expire) {
                orders.push_back(order.copy_order());
            };

            cur = book.cursor_next(bids, cur);
        };

        // The walk advances past the last order it took, so a non-null cursor here
        // means the limit was what stopped it and more orders remain.
        let has_next_page = !stopped_by_end && !cur.cursor_is_null();

        OrderPage { orders, has_next_page }
    }

    public fun orders(self: &OrderPage): &vector<Order> {
        &self.orders
    }

    public fun has_next_page(self: &OrderPage): bool {
        self.has_next_page
    }
}
