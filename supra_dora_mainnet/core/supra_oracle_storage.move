/// This module manages price feeds for trading pairs and interacts with the validator module to process Oracle Committee information.
/// It provides functions for updating price feeds, checking for history consistency data, and retrieving price information.
///
/// Auction:
/// Free-node - The free-node can perform the `verify_oracle_proof` function in the price_data_pull module.
/// User - The user can use the `get_price`, `get_prices`, `get_derived_price`, and `extract_price` public functions
module supra_oracle::supra_oracle_storage {

    use std::vector;
    use std::error;
    use aptos_std::table;
    use supra_framework::object;
    use supra_framework::event;
    use supra_framework::timestamp;
    use supra_framework::multisig_account;
    use supra_utils::utils;
    use supra_oracle::supra_oracle_hcc;

    friend supra_oracle::supra_oracle_pull;

    /// User Requesting for invalid pair or subscription
    const EINVALID_PAIR: u64 = 300;
    /// PairId1 and PairId2 should not be same
    const EPAIR_ID_SAME: u64 = 301;
    /// Invalid Operation, it should be 0 => Multiplication || 1 => Division
    const EINVALID_OPERATION: u64 = 302;
    /// Invalid decimal, it should not be more than [MAX_DECIMAL]
    const EINVALID_DECIMAL: u64 = 303;
    /// Invalid Multisig account
    const EINVALID_MULTISIG_ACCOUNT: u64 = 304;

    /// Keeping the decimal for the derived prices as 18
    const MAX_DECIMAL: u16 = 18;

    /// Defined Oracle seeds that are used for creating resources
    const SEED_ORACLE: vector<u8> = b"supra_oracle_storage::OracleHolder";
    /// Time Delta allowance in millisecond
    const TIME_DELTA_ALLOWANCE: u64 = 10000;
    /// Conversion factor between microseconds and millisecond || millisecond and second
    const MILLISECOND_CONVERSION_FACTOR: u64 = 1000;


    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct OracleHolderObjectController has key {
        transfer_ref: object::TransferRef,
        extend_ref: object::ExtendRef,
    }


    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    /// Manage price feeds of respective pairs in HashMap/VectorMap
    struct OracleHolder has key, store {
        feeds: table::Table<u32, Entry>,

    }

    /// Pair data value structure
    struct Entry has drop, store {
        value: u128,
        decimal: u16,
        timestamp: u64,
        round: u64,
    }

    #[event]
    /// Return type of the price that we are given to customer
    struct Price has store, drop {
        pair: u32,
        value: u128,
        decimal: u16,
        timestamp: u64,
        round: u64
    }

    /// Its Initial function which will be executed automatically while deployed packages
    fun init_module(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer,SEED_ORACLE);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer,OracleHolderObjectController{transfer_ref:object::generate_transfer_ref(&cons_ref),extend_ref:object::generate_extend_ref(&cons_ref)});
        move_to(&object_signer, OracleHolder { feeds: table::new() });
    }

    entry fun migrate_to_multisig(owner_signer: &signer, multisig_address:address) acquires OracleHolderObjectController {
        assert!(
            multisig_account::num_signatures_required(multisig_address) >= 2,
            error::invalid_state(EINVALID_MULTISIG_ACCOUNT)
        );
        let oracle_holder_address = get_oracle_holder_address();
        utils::ensure_object_owner(object::address_to_object<OracleHolderObjectController>(oracle_holder_address),owner_signer);
        let object_controller = borrow_global_mut<OracleHolderObjectController>(oracle_holder_address);
        let linear_transfer_ref = object::generate_linear_transfer_ref(&object_controller.transfer_ref);
        object::transfer_with_ref(linear_transfer_ref,multisig_address);
    }


    /// Internal function
    /// If the specified pair already exists in the Oracle Holder, update the entry if the new timestamp is greater.
    /// If the pair does not exist, add a new pair with the provided entry to the Oracle Holder.
    fun upsert_pair_data(oracle_holder: &mut OracleHolder, pair: u32, entry: Entry) {
        let block_timestamp_ms = timestamp::now_microseconds() / MILLISECOND_CONVERSION_FACTOR;
        // new round/timestamp should be less than current block timestamp
        assert!(entry.round < (block_timestamp_ms + TIME_DELTA_ALLOWANCE), error::invalid_state(entry.round - block_timestamp_ms));
        if (is_pair_exist(oracle_holder,pair)) {
            let feed = table::borrow_mut(&mut oracle_holder.feeds, pair);

            // Update the price only if "stored round" is less than "round"
            if (feed.round < entry.round) {
                emit_price_update_event(pair, &entry);
                *feed = entry;

            }
        } else {
            emit_price_update_event(pair, &entry);
            table::add(&mut oracle_holder.feeds, pair, entry);
        };
    }

    /// Internal function - This function is emitting event that pair data is update/add
    fun emit_price_update_event(pair: u32, entry: &Entry) {
        let pair_feed = Price { pair, value: entry.value, timestamp: entry.timestamp, decimal: entry.decimal, round: entry.round };
        event::emit(pair_feed);
    }

    /// Friend function - To upsert pair data
    public(friend) fun get_oracle_holder_and_upsert_pair_data(
        pair: u32,
        value: u128,
        decimal: u16,
        timestamp: u64,
        round: u64
    ) acquires OracleHolder {
        let oracle_holder = borrow_global_mut<OracleHolder>(get_oracle_holder_address());
        let entry = Entry { value, decimal, timestamp, round };
        upsert_pair_data(oracle_holder, pair, entry);
        if(supra_oracle_hcc::under_hcc(pair)){
            supra_oracle_hcc::compute_hcc(
                pair,
                value);
        };
    }

    /// Function which checks that is pair index is exist in OracleHolder
    public fun is_pair_exist(oracle_holder: &OracleHolder, pair_index: u32): bool {
        table::contains(&oracle_holder.feeds, pair_index)
    }

    #[view]
    /// Function which checks that is pair index is exist in OracleHolder
    public fun does_pair_exist(pair_index: u32): bool acquires OracleHolder {
        let oracle_holder = borrow_global<OracleHolder>(get_oracle_holder_address());
        table::contains(&oracle_holder.feeds, pair_index)
    }

    #[view]
    /// External view function
    /// It will return OracleHolder resource address
    public fun get_oracle_holder_address(): address {
        object::create_object_address(&@supra_oracle, SEED_ORACLE)
    }

    #[view]
    /// External view function
    /// It will return the priceFeedData value for that particular tradingPair
    public fun get_price(pair: u32): (u128, u16, u64, u64) acquires OracleHolder {
        let oracle_holder = borrow_global<OracleHolder>(get_oracle_holder_address());
        assert!(is_pair_exist(oracle_holder,pair), error::invalid_state(EINVALID_PAIR));
        let feed = table::borrow(&oracle_holder.feeds, pair);
        (feed.value, feed.decimal, feed.timestamp, feed.round)
    }



    #[view]
    /// External view function
    /// It will return the priceFeedData value for that multiple tradingPair
    /// If any of the pairs do not exist in the OracleHolder, an empty vector will be returned for that pair.
    /// If a client requests 10 pairs but only 8 pairs exist, only the available 8 pairs' price data will be returned.
    public fun get_prices(pairs: vector<u32>): vector<Price> acquires OracleHolder {
        let oracle_holder = borrow_global<OracleHolder>(get_oracle_holder_address());
        let prices: vector<Price> = vector::empty();

        vector::for_each_reverse(pairs, |pair| {
            if (is_pair_exist(oracle_holder,pair)) {
                let feed = table::borrow(&oracle_holder.feeds, pair);
                vector::push_back(
                    &mut prices,
                    Price { pair, value: feed.value, decimal: feed.decimal, timestamp: feed.timestamp, round: feed.round }
                );
            };
        });
        prices
    }

    /// External public function
    /// It will return the extracted price value for the Price struct
    public fun extract_price(price: &Price): (u32, u128, u16, u64, u64) {
        (price.pair, price.value, price.decimal, price.timestamp, price.round)
    }

    #[view]
    /// External public function.
    /// This function will help to find the prices of the derived pairs
    /// Derived pairs are the one whose price info is calculated using two compatible pairs using either multiplication or division.
    /// Return values in tuple
    ///     1. derived_price : u32
    ///     2. decimal : u16
    ///     3. round-difference : u64
    ///     4. `"pair_id1" as compared to "pair_id2"` : u8 (Where 0=>EQUAL, 1=>LESS, 2=>GREATER)
    public fun get_derived_price(
        pair_id1: u32,
        pair_id2: u32,
        operation: u8
    ): (u128, u16, u64, u8) acquires OracleHolder {
        assert!(pair_id1 != pair_id2, EPAIR_ID_SAME);
        assert!((operation <= 1), EINVALID_OPERATION);

        let (value1, decimal1, _timestamp1, round1) = get_price(pair_id1);
        let (value2, decimal2, _timestamp2, round2) = get_price(pair_id2);
        let value1 = (value1 as u256);
        let value2 = (value2 as u256);

        // used variable name with `_` to remove compilation warning
        let _derived_price: u256 = 0;

        // operation 0 it means multiplication
        if (operation == 0) {
            let sum_decimal_1_2 = decimal1 + decimal2;
            if (sum_decimal_1_2 > MAX_DECIMAL) {
                _derived_price = (value1 * value2) / (utils::calculate_power(10, (sum_decimal_1_2 - MAX_DECIMAL)));
            } else {
                _derived_price = (value1 * value2) * (utils::calculate_power(10, (MAX_DECIMAL - sum_decimal_1_2)));
            }
        } else {
            _derived_price = (scale_price(value1, decimal1) * (utils::calculate_power(10, MAX_DECIMAL))) / scale_price(
                value2,
                decimal2
            )
        };

        let base_compare_to_quote = 0; // default consider as equal
        let round_difference = if (round1 > round2) {
            base_compare_to_quote = 2;
            round1 - round2
        } else if (round1 < round2) {
            base_compare_to_quote = 1;
            round2 - round1
        } else { 0 };
        ((_derived_price as u128), MAX_DECIMAL, round_difference, base_compare_to_quote)
    }

    /// Scales a price value by adjusting its decimal precision.
    fun scale_price(price: u256, decimal: u16): u256 {
        assert!(decimal <= MAX_DECIMAL, error::invalid_argument(EINVALID_DECIMAL));
        if (decimal == MAX_DECIMAL) { price }
        else { price * (utils::calculate_power(10, (MAX_DECIMAL - decimal))) }
    }

    #[test_only]
    public fun create_oracle_holder_for_test(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer,SEED_ORACLE);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer, OracleHolder { feeds: table::new()});
    }

    #[test_only]
    public fun add_pair_data_for_test(
        pair: u32,
        value: u128,
        decimal: u16,
        timestamp: u64,
        round: u64
    ) acquires OracleHolder {
        let entry = Entry { value, decimal, timestamp, round };
        let oracle_holder = borrow_global_mut<OracleHolder>(get_oracle_holder_address());
        upsert_pair_data(oracle_holder, pair, entry);
    }
}
