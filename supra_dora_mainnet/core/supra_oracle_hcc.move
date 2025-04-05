module supra_oracle::supra_oracle_hcc {
    use std::vector;
    use std::error;
    use aptos_std::table;
    use supra_framework::event;
    use supra_framework::object;
    use supra_framework::multisig_account;
    use supra_utils::enumerable_set::{Self,EnumerableSet};
    use supra_utils::enumerable_map::{Self,EnumerableMap};
    use supra_utils::ring_buffer::{Self,RingBuffer};
    use supra_utils::utils;

    friend supra_oracle::supra_oracle_storage;


    /// Vector having no values
    const EEMPTY_VECTOR : u64 = 400;
    /// Invalid Pair Id for hcc
    const EALREADY_ADDED_PAIR : u64 = 401;
    /// Invalid Multisig account
    const EINVALID_MULTISIG_ACCOUNT: u64 = 402;
    /// Variance Too High
    const EVARIANCE_TOO_HIGH: u64 = 403;
    /// User Requesting for invalid pair not under HCC
    const EINVALID_PAIR: u64 = 404;
    /// Window Size to store past data
    const MAX_WINDOW_SIZE: u64 = 50;
    /// Default value of HCC constant
    const DEFAULT_HCC_CONSTANT: u128 = 3;


    /// HCC pair object address seed
    const SEED_HCCPAIR: vector<u8> = b"supra_oracle_hcc::HccPairs";

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct HccObjectController has key {
        transfer_ref: object::TransferRef,
        extend_ref: object::ExtendRef,
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct HccPairs has key {
        hcc_value: table::Table<u32,u8>, // pair id -> hcc_value(0,1,2) 0-> not consistent with history 1-> consistent with history 2-> Not calculated yet
        hcc_pairs:EnumerableSet<u32>,  // pair id -> index of pair id in the list
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct HccPriceClusters has key {
        aggregate: EnumerableMap<u32,PairAggregate>,
        pairPriceData: table::Table<u32, RingBuffer<u128>>, //pair_id -> price window of length MAX_WINDOW_SIZE
        constant: u128,
    }

    /// Structure to store different aggreagted values of pair
    struct PairAggregate has store,copy,drop {
        sum: u128,
        sum_of_squares: u256,
    }

    /// HCC return value for a pair
    struct HccValue has store,drop,copy {
        pair_id: u32,
        hcc_value: u8,
    }

    #[event]
    /// Add HCC pair id event
    struct HCCPairAdd has store, drop { pair_id: u32 }

    #[event]
    /// Add Multiple HCC pair id event
    struct MultipleHCCPairAdd has store, drop { pair_ids: vector<u32> }

    #[event]
    /// Remove HCC pair id event
    struct HCCPairRemove has store, drop { pair_id: u32 }

    #[event]
    /// Remove Multiple HCC pair id event
    struct MultipleHCCPairRemove has store, drop { pair_ids : vector<u32> }

    #[event]
    /// Update the HCC constant event
    struct HccConstantUpdated has store, drop { old_constant : u128, new_constant : u128 }

    /// Its Initial function which will be executed automatically while deployed packages
    fun init_module(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer,SEED_HCCPAIR);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer,HccObjectController{transfer_ref:object::generate_transfer_ref(&cons_ref),extend_ref:object::generate_extend_ref(&cons_ref)});
        move_to(&object_signer, HccPairs { hcc_value:table::new(), hcc_pairs:enumerable_set::new_set<u32>() });
        move_to(&object_signer, HccPriceClusters {aggregate:enumerable_map::new_map<u32,PairAggregate>(), pairPriceData:table::new(), constant:DEFAULT_HCC_CONSTANT });
    }


    entry fun migrate_to_multisig(owner_signer: &signer, multisig_address:address) acquires HccObjectController {
        assert!(
            multisig_account::num_signatures_required(multisig_address) >= 2,
            error::invalid_state(EINVALID_MULTISIG_ACCOUNT)
        );
        let hcc_pair_addr = get_hcc_pair_object_address();
        utils::ensure_object_owner(object::address_to_object<HccObjectController>(hcc_pair_addr),owner_signer);
        let object_controller = borrow_global_mut<HccObjectController>(hcc_pair_addr);
        let linear_transfer_ref = object::generate_linear_transfer_ref(&object_controller.transfer_ref);
        object::transfer_with_ref(linear_transfer_ref,multisig_address);
    }

    /// Add Single HCC pair ID flag
    /// Only Owner can perform this action
    entry public fun add_hcc_pair_flag(owner_signer: &signer, pair_id: u32) acquires HccPairs {

        assert!(!under_hcc(pair_id), error::invalid_state(EALREADY_ADDED_PAIR));
        let hcc_pair_addr = get_hcc_pair_object_address();
        utils::ensure_object_owner(object::address_to_object<HccPairs>(hcc_pair_addr),owner_signer);
        enumerable_set::push_value(&mut borrow_global_mut<HccPairs>(hcc_pair_addr).hcc_pairs,pair_id);
        // emit event
        event::emit(HCCPairAdd{pair_id});
    }

    /// Add Multiple HCC pairs ID flag in bulk
    /// Only Owner can perform this action
    entry public fun add_hcc_pair_flag_bulk(owner_signer: &signer, pair_ids: vector<u32>) acquires HccPairs {
        let hcc_pair_addr = get_hcc_pair_object_address();
        utils::ensure_object_owner(object::address_to_object<HccPairs>(hcc_pair_addr),owner_signer);
        let event_pair_ids=enumerable_set::push_value_bulk(&mut borrow_global_mut<HccPairs>(hcc_pair_addr).hcc_pairs,pair_ids);
        assert!(!vector::is_empty(&event_pair_ids),error::invalid_state(EEMPTY_VECTOR));
        // emit event
        event::emit(MultipleHCCPairAdd{pair_ids:event_pair_ids});
    }

    /// Remove single HCC pair ID flag
    /// Only Owner can perform this action
    entry public fun remove_hcc_pair_flag(owner_signer: &signer, pair_id: u32) acquires HccPairs {
        let hcc_pair_addr = get_hcc_pair_object_address();
        utils::ensure_object_owner(object::address_to_object<HccPairs>(hcc_pair_addr),owner_signer);
        enumerable_set::pop_value(&mut borrow_global_mut<HccPairs>(hcc_pair_addr).hcc_pairs,pair_id);
        // emit event
        event::emit(HCCPairRemove{pair_id});
    }

    /// Remove Multiple HCC pairs ID flag in bulk
    /// Only Owner can perform this action
    entry public fun remove_hcc_pair_flag_bulk(owner_signer: &signer, pair_ids: vector<u32>) acquires HccPairs {
        let hcc_pair_addr = get_hcc_pair_object_address();

        utils::ensure_object_owner(object::address_to_object<HccPairs>(hcc_pair_addr),owner_signer);
        let event_pair_ids = enumerable_set::pop_value_bulk(&mut borrow_global_mut<HccPairs>(hcc_pair_addr).hcc_pairs,pair_ids);
        assert!(!vector::is_empty(&event_pair_ids),error::invalid_state(EEMPTY_VECTOR));

        // emit event
        event::emit(MultipleHCCPairRemove{pair_ids:event_pair_ids});
    }


    /// Updates the HCC constant for future
    entry public fun update_hcc_constant(owner_signer: &signer, new_constant:u128) acquires HccPriceClusters {

        let hcc_pair_addr = get_hcc_pair_object_address();
        utils::ensure_object_owner(object::address_to_object<HccPriceClusters>(hcc_pair_addr),owner_signer);
        let constant =&mut  borrow_global_mut<HccPriceClusters>(hcc_pair_addr).constant;
        event::emit(HccConstantUpdated{old_constant: *constant, new_constant:new_constant});
        *constant = new_constant;

    }

    fun upsert_hcc(pair_id: u32, current_hcc_value: u8) acquires HccPairs {
        let hcc_value =&mut borrow_global_mut<HccPairs>(get_hcc_pair_object_address()).hcc_value;
        table::upsert(hcc_value,pair_id,current_hcc_value);
    }

    /// Friend function of svalue_feed_holder module
    /// This function will be called whenever we get new pair data if the pair is Under HCC
    public(friend) fun compute_hcc(pair: u32, current_price: u128) acquires HccPairs,HccPriceClusters {

            let dora_state = borrow_global_mut<HccPriceClusters>(get_hcc_pair_object_address());
            let pair_aggregate = enumerable_map::get_value(&mut dora_state.aggregate,pair,PairAggregate{sum:0,sum_of_squares:0});
            let pair_price_list = table::borrow_mut_with_default(&mut dora_state.pairPriceData,pair,ring_buffer::new<u128>(MAX_WINDOW_SIZE));
            let stale_price = ring_buffer::get_stale_value(pair_price_list,0);
            let prev_price = ring_buffer::get_value(pair_price_list,0);
            ring_buffer::push_value(pair_price_list,current_price);
            let sum = pair_aggregate.sum;
            let sum_of_squares = pair_aggregate.sum_of_squares;
            let constant = dora_state.constant;

            if (ring_buffer::length(pair_price_list) == MAX_WINDOW_SIZE) {
                sum = sum + current_price - stale_price;
                sum_of_squares = (sum_of_squares + ((current_price as u256) * (current_price as u256))) - ((stale_price as u256) * (stale_price as u256));
                enumerable_map::update_value(&mut dora_state.aggregate, pair, PairAggregate{sum,sum_of_squares});
                let variance = find_variance(sum, sum_of_squares);
                let standard_deviation = find_standard_deviation(variance);

                let lower_bound:u128;
                let upper_bound:u128;
                if (prev_price < (constant * standard_deviation))
                    lower_bound = 0
                else
                    lower_bound = prev_price - (constant * standard_deviation);
                upper_bound = prev_price + (constant * standard_deviation);

                if (lower_bound <= current_price && upper_bound >= current_price) {
                    upsert_hcc(pair, 1);
                }
                else {
                    upsert_hcc(pair, 0);
                }
            }
            else {
                if (!enumerable_map::contains(& dora_state.aggregate, pair)) {
                    enumerable_map::add_value(&mut dora_state.aggregate, pair, PairAggregate{sum:current_price,sum_of_squares:(current_price as u256) * (current_price as u256)});
                }
                else {
                    enumerable_map::update_value(&mut dora_state.aggregate, pair, PairAggregate{sum:sum+current_price,sum_of_squares:sum_of_squares+((current_price as u256) * (current_price as u256))});
                };
                upsert_hcc(pair, 2);
            }


    }

    /// TO find the variance using the simplified formulae
    fun find_variance(sum: u128, sum_of_squares: u256) : u256 {

        let numerator =((MAX_WINDOW_SIZE as u256) * sum_of_squares) - ((sum as u256) * (sum as u256));
        let denominator = ((MAX_WINDOW_SIZE * MAX_WINDOW_SIZE) as u256) ;
        let variance = numerator/denominator;

        let check_for_closest_int_1 = utils::abs_difference(numerator , variance * denominator) ;
        let check_for_closest_int_2 = utils::abs_difference((variance+1) * denominator , numerator) ;

        if(check_for_closest_int_1 < check_for_closest_int_2) {
            return variance
        }
        else {
            return variance+1
        }
    }
    
    
    /// Helper funtion to find the square root of a number
    /// In this function we are finding the standard deviation from variance
    fun find_standard_deviation(variance : u256) : u128 {

        if(variance==0) return 0;
        let variance_bits = (utils::num_bits(variance) as u16);
        assert!(variance_bits < 256, error::invalid_state(EVARIANCE_TOO_HIGH));
        let high_candidate = utils::max_x_bits ((variance_bits/2) + 1);

        let low : u256 = 0;
        let high: u256 =  if (variance > high_candidate) high_candidate else variance;
        let _guess = 0;
        let _guess_squared = 0;
        while(low < high-1) {
            _guess = (low+high)/2;
            _guess_squared = _guess * _guess;
            if (_guess_squared < variance) {
                low = _guess;
            } else {
                high = _guess;
            }
        };
        let high_diff = utils::abs_difference(variance,high * high);
        let low_diff = utils::abs_difference(variance,low * low);

        if (low_diff < high_diff) {
            (low as u128)
        } else {
            (high as u128)
        }
    }



    #[view]
    /// to get object address of HccPairs,HccPairClusters and HccObjectController easily
    public fun get_hcc_pair_object_address(): address {
        object::create_object_address(&@supra_oracle, SEED_HCCPAIR)
    }

    #[view]
    /// Returns the list of pairs under HCC
    public fun hcc_pair_list(): vector<u32> acquires HccPairs {
        return enumerable_set::ennumerable_set_list(& borrow_global<HccPairs>(get_hcc_pair_object_address()).hcc_pairs)
    }

    #[view]
    /// External view function
    /// It will return the Pair Value List for that particular tradingPair if its under HCC
    public fun get_price_list(pair: u32): vector<u128> acquires HccPairs,HccPriceClusters {
        let oracle_holder = borrow_global<HccPriceClusters>(get_hcc_pair_object_address());
        assert!(under_hcc(pair), error::invalid_state(EINVALID_PAIR));
        let feed = table::borrow(&oracle_holder.pairPriceData, pair);
        ring_buffer::ring_buffer_list(feed)
    }

    #[view]
    /// It will return if the pair is under History Consistency Check or not
    public fun under_hcc(pair_id: u32): bool acquires HccPairs {
        return enumerable_set::contains(& borrow_global<HccPairs>(get_hcc_pair_object_address()).hcc_pairs,pair_id)
    }

    #[view]
    /// It will return the current HCC value of list of pairs
    public fun get_hcc_value(pair_ids: vector<u32>): vector<HccValue> acquires HccPairs {
        let hcc_pairs = borrow_global<HccPairs>(get_hcc_pair_object_address());
        let hcc:vector<HccValue> = vector::empty<HccValue>();
        vector::for_each_reverse(pair_ids, |pair_id| {
            if(enumerable_set::contains(& hcc_pairs.hcc_pairs,pair_id)){
                let hcc_value = *table::borrow_with_default<u32,u8>(&hcc_pairs.hcc_value,pair_id,&2);
                vector::push_back<HccValue>(&mut hcc,HccValue{pair_id,hcc_value});
            }

        });
        return hcc
    }

    #[test_only]
    public fun create_oracle_hcc_for_test(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer,SEED_HCCPAIR);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer,HccObjectController{transfer_ref:object::generate_transfer_ref(&cons_ref),extend_ref:object::generate_extend_ref(&cons_ref)});
        move_to(&object_signer, HccPairs { hcc_value:table::new(), hcc_pairs:enumerable_set::new_set<u32>() });
        move_to(&object_signer, HccPriceClusters {aggregate:enumerable_map::new_map<u32,PairAggregate>(),pairPriceData: table::new(), constant:0 });
    }

    #[test]
    public fun test_num_bits_u256() {
        let value_u256 = utils::max_x_bits(256) - 5;
        assert!(utils::num_bits(value_u256) == 256,0);
    }

    #[test]
    public fun test_num_bits_u128() {
        let value_u128 = utils::max_x_bits(128) - 4;
        assert!(utils::num_bits(value_u128) == 128,0);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    public fun test_fail_num_bits_u127() {
        let value_u127 = utils::max_x_bits(127) - 4;
        assert!(utils::num_bits(value_u127) == 128,0);
    }

    #[test]
    public fun test_num_bits_u64() {
        let value_u64 = utils::max_x_bits(64) - 8;
        assert!(utils::num_bits(value_u64) == 64,0);
    }

    #[test]
    public fun test_num_bits_u32() {
        let value_u32 = utils::max_x_bits(32) - 2;
        assert!(utils::num_bits(value_u32) == 32,0);
    }

    #[test]
    public fun test_num_bits_u16() {
        let value_u16 = utils::max_x_bits(16) - 8;
        assert!(utils::num_bits(value_u16) == 16,0);
    }

    #[test]
    public fun test_num_bits_u8() {
        let value_u8 = utils::max_x_bits(8) - 5;
        assert!(utils::num_bits(value_u8) == 8,0);
    }

    #[test]
    public fun test_num_bits_any_u8() {
        let value_u8 = 7;
        assert!(utils::num_bits(value_u8) == 3,0);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    public fun test_fail_num_bits_any_u8() {
        let value_u8 = 8;
        assert!(utils::num_bits(value_u8) == 3,0);
    }

    #[test]
    public fun test_find_std_deviation() {
        let variance = 25;
        assert!(find_standard_deviation(variance)==5,1);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    public fun test_fail_find_std_deviation() {
        let variance = 25;
        assert!(find_standard_deviation(variance)==4,1);
    }


}