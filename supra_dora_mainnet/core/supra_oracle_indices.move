/// # Indices Smart Contract
///
/// ## Overview
/// This smart contract module is designed to manage and interact with indices in a decentralized
/// manner. It allows users to create, update, delete, and calculate values for indices based on
/// predefined pair IDs and weights. Each index is associated with a unique identifier and
/// includes information such as the owner, initial value, scaling factor, and weights.
module supra_oracle::supra_oracle_indices {
    use std::error;
    use std::signer;
    use std::vector;
    use aptos_std::table::{Self, Table};
    use supra_framework::event;
    use supra_framework::object::{Self, Object};
    use supra_framework::timestamp;
    use supra_framework::multisig_account;
    use supra_oracle::supra_oracle_storage;
    use supra_utils::utils;

    /// Error code for missing length in vector-type parameters
    const EMISSING_LENGTH: u64 = 500;
    /// Error code for invalid index ID
    const EINVALID_INDEX_ID: u64 = 501;
    /// Error code for when the price decimal is out of bounds (greater than MAX_INDEX_DECIMAL)
    const EINVALID_INDEX_DECIMAL: u64 = 502;
    /// timestamp being out of the current time range
    const EOUT_OF_CURRENT_TIME_RANGE: u64 = 503;
    /// Invalid Multisig account
    const EINVALID_MULTISIG_ACCOUNT: u64 = 504;

    /// Maximum decimal value for the index is 18
    const MAX_INDEX_DECIMAL: u16 = 18;
    /// Conversion factor between microseconds and millisecond || millisecond and second
    const MILLISECOND_CONVERSION_FACTOR: u64 = 1000;

    /// Seed for the Index object
    const INDEX_MANAGER_SEED: vector<u8> = b"supra_oracle_indices::IndexManager";

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct IndexManager has key {
        // Incremental index updated each time a new index is added
        current_index: u64,
        // Mapping of index_id to Index details
        index_map: Table<u64, ObjectController>
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct IndexManagerController has key, store, drop {
        extend_ref: object::ExtendRef,
        transfer_ref: object::TransferRef,
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct ObjectController has key, store, drop {
        // Object address of the Index
        object_addr: address,
        extend_ref: object::ExtendRef,
        transfer_ref: object::TransferRef,
        delete_ref: object::DeleteRef,
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct Index has key, copy, drop {
        // unique identifier for the index
        id: u64,
        pair_ids: vector<u32>,
        init_value: u256,
        init_index_time: u64,
        last_update_time: u64,
        scaling_factor: u256,
        scaled_weights: vector<u256>,
        index_decimal: u16,
        index_value: u256
    }

    #[event]
    struct CreateIndex has store, drop {
        id: u64,
        pair_ids: vector<u32>,
        weights: vector<u32>,
        init_value: u256,
        init_index_time: u64,
        scaling_factor: u256,
        scaled_weights: vector<u256>,
        index_decimal: u16,
        creator: address,
        index_obj_addr: address
    }

    #[event]
    struct UpdateIndex has store, drop {
        id: u64,
        pair_ids: vector<u32>,
        weights: vector<u32>,
        update_index_time: u64,
        scaled_weights: vector<u256>,
        index_obj_addr: address
    }

    #[event]
    struct DeleteIndex has store, drop {
        id: u64,
        delete_index_time: u64,
        index_obj_addr: address
    }

    #[event]
    struct CalculateIndex has store, drop {
        ids: vector<u64>,
        index_value_list: vector<u256>,
        calculate_index_time: vector<u64>,
        index_obj_addrs: vector<address>
    }

    /// Initial function executed automatically when the package is deployed.
    /// Creates a new named object using `INDEX_MANAGER_SEED` and stores `IndexManager`
    fun init_module(owner_signer: &signer) {
        let constructor_ref = object::create_named_object(owner_signer, INDEX_MANAGER_SEED);
        let object_signer = object::generate_signer(&constructor_ref);
        move_to(&object_signer, IndexManager { current_index: 0, index_map: table::new() });
        move_to(&object_signer, IndexManagerController {
            extend_ref: object::generate_extend_ref(&constructor_ref),
            transfer_ref: object::generate_transfer_ref(&constructor_ref),
        });
    }

    entry fun migrate_to_multisig(owner_signer: &signer, multisig_address:address) acquires IndexManagerController {
        assert!(
            multisig_account::num_signatures_required(multisig_address) >= 2,
            error::invalid_state(EINVALID_MULTISIG_ACCOUNT)
        );
        let merkle_root_address = get_index_manager_address();
        utils::ensure_object_owner(object::address_to_object<IndexManagerController>(merkle_root_address),owner_signer);
        let object_controller = borrow_global_mut<IndexManagerController>(merkle_root_address);
        let linear_transfer_ref = object::generate_linear_transfer_ref(&object_controller.transfer_ref);
        object::transfer_with_ref(linear_transfer_ref,multisig_address);
    }

    /// Ensures that the index with the given ID exists in the table.
    fun ensure_index_exist(index_manager: &IndexManager, index_id: u64) {
        assert!(
            table::contains(&index_manager.index_map, index_id),
            error::not_found(EINVALID_INDEX_ID)
        )
    }

    /// Adjusts the weights to match the target initial value by scaling each weight.
    /// Returned value is implicitly in MAX_INDEX_DECIMAL precision
    fun scale_weights_to_target_initial_value(weights: vector<u32>, scaling_factor: u256): vector<u256> {
        let scaled_weights = vector[];
        vector::for_each(weights, |weight| {
            // weight multiplies it by the `scaling_factor` to find scaled weight.
            vector::push_back(&mut scaled_weights, (weight as u256) * scaling_factor);
        });
        scaled_weights
    }

    /// Computes the sum of pair values weighted by the corresponding weights.
    /// Result implicitly has MAX_INDEX_DECIMAL precision
    fun compute_weighted_pair_sum(pair_ids: vector<u32>, weights: vector<u32>): (u256, u64) {
        let sum = 0;
        let latest_pair_update_time = 0;
        let (_pair_index_value, _pair_timestamp) = (0, 0);
        vector::zip_ref(&pair_ids, &weights, |pair, weight| {
            (_pair_index_value, _pair_timestamp) = get_pair_value_with_weight(*pair, (*weight as u256));
            // Get the value of the pair with weight and add it to the sum
            sum = sum + _pair_index_value;

            // Every time we get a pair timestamp, check if the pair timestamp is larger than `latest_pair_update_time`.
            // If yes, then assign this timestamp to `latest_pair_update_time`.
            if (_pair_timestamp > latest_pair_update_time) {
                latest_pair_update_time = _pair_timestamp;
            };
        });
        (sum, latest_pair_update_time)
    }

    /// Calculates the scaling factor for the initial value.
    /// The returned scaling factor is in [MAX_INDEX_DECIMAL] decimal.
    fun init_value_scaling_factor(pair_ids: vector<u32>, weights: vector<u32>, init_value: u256): (u256, u64) {
        let (sum, latest_pair_update_time) = compute_weighted_pair_sum(pair_ids, weights);
        // Convert the init_value to 10^((MAX_INDEX_DECIMAL * 2)) decimal
        let init_value = init_value * utils::calculate_power(10, MAX_INDEX_DECIMAL);
        ((init_value / sum), latest_pair_update_time)
    }

    /// Gets the pair value and converts it to [MAX_INDEX_DECIMAL], then multiplies it by the weight.
    fun get_pair_value_with_weight(pair: u32, weight: u256): (u256, u64) {
        let (value, decimal, timestamp, _) = supra_oracle_storage::get_price(pair);
        let value = (value as u256);
        let fix_decimal_value = value;
        assert!(decimal <= MAX_INDEX_DECIMAL, error::out_of_range(EINVALID_INDEX_DECIMAL));
        // Convert the value to `MAX_INDEX_DECIMAL` if it's not
        if (decimal < MAX_INDEX_DECIMAL) {
            fix_decimal_value = (value * utils::calculate_power(10, MAX_INDEX_DECIMAL - decimal));
        };
        ((fix_decimal_value * weight), (timestamp as u64))
    }

    /// Gets the pair value with the scaled weight.
    /// Returns `(u256, u128)` - A tuple where the first value is the calculated pair value with the scaled weight,
    ///                    and the second value is the pair's last updated timestamp.
    fun get_pair_value_with_scaled_weight(pair: u32, scaled_weight: u256): (u256, u64) {
        let (value, decimal, timestamp, _) = supra_oracle_storage::get_price(pair);
        // Multiply pair value with scaled weight and divide by 10^decimal to remove `MAX_INDEX_DECIMAL` decimal places
        let pair_index_value = ((value as u256) * scaled_weight) / utils::calculate_power(10, decimal);
        (pair_index_value, (timestamp as u64))
    }

    /// Calculates the overall index value by summing the weighted values of its pairs,
    /// and determines the latest update timestamp among those pairs.
    fun compute_index_value(index: &Index): (u256, u64) {
        let total_index_value = 0;
        let latest_update_timestamp = 0;

        let (_pair_value, _pair_timestamp) = (0, 0);
        vector::zip_ref(&index.pair_ids, &index.scaled_weights, |pair_id, scaled_weight| {
            // Get the value of the pair with the scaled weight, and the pair's last updated timestamp
            (_pair_value, _pair_timestamp) = get_pair_value_with_scaled_weight(*pair_id, *scaled_weight);

            // Update the latest update timestamp if the current pair's timestamp is more recent
            if (_pair_timestamp > latest_update_timestamp) {
                latest_update_timestamp = _pair_timestamp;
            };

            // Accumulate the weighted value of the pair to the total index value
            total_index_value = total_index_value + _pair_value;
        });

        (total_index_value, latest_update_timestamp)
    }

    /// Internal function to create an index.
    fun create_index_helper(
        owner_signer: &signer,
        pair_ids: vector<u32>,
        weights: vector<u32>,
        init_value: u256,
        scaling_factor: u256,
        latest_pair_update_time: u64
    ) acquires IndexManager {
        let index_manager = borrow_global_mut<IndexManager>(get_index_manager_address());
        index_manager.current_index = index_manager.current_index + 1;

        let scaled_weights = scale_weights_to_target_initial_value(weights, scaling_factor);

        // Retrieves a signer for the object
        let constructor_ref = object::create_object(signer::address_of(owner_signer));
        let object_signer = object::generate_signer(&constructor_ref);
        let init_index_time = timestamp::now_microseconds() / MILLISECOND_CONVERSION_FACTOR;
        let id = index_manager.current_index;

        move_to(
            &object_signer,
            Index { id, pair_ids, init_value, init_index_time, last_update_time: latest_pair_update_time, index_decimal: MAX_INDEX_DECIMAL, scaling_factor, scaled_weights, index_value: init_value }
        );

        let index_obj_addr = signer::address_of(&object_signer);
        table::add(&mut index_manager.index_map, id, ObjectController {
            object_addr: index_obj_addr,
            extend_ref: object::generate_extend_ref(&constructor_ref),
            transfer_ref: object::generate_transfer_ref(&constructor_ref),
            delete_ref: object::generate_delete_ref(&constructor_ref)
        });

        // Emit the event for created Index
        let creator = signer::address_of(owner_signer);
        event::emit(
            CreateIndex { id, pair_ids, weights, init_value, init_index_time, scaling_factor, scaled_weights, index_decimal: MAX_INDEX_DECIMAL, creator, index_obj_addr }
        );
    }

    /// Public entry function to create a new index without an initial value (default init_value = INIT_VALUE).
    /// This function can be accessed by anyone
    public entry fun create_index(
        owner_signer: &signer,
        pair_ids: vector<u32>,
        weights: vector<u32>,
    ) acquires IndexManager {
        // The length of both parameters should be the same
        assert!(vector::length(&pair_ids) == vector::length(&weights), error::invalid_argument(EMISSING_LENGTH));

        let (init_value, latest_pair_update_time) = compute_weighted_pair_sum(pair_ids, weights);

        // scaling factor is 1 and multiply with 10^MAX_INDEX_DECIMAL
        let scaling_factor = utils::calculate_power(10, MAX_INDEX_DECIMAL);
        create_index_helper(owner_signer, pair_ids, weights, init_value, scaling_factor, latest_pair_update_time);
    }

    /// Public entry function to create a new index with an initial value.
    /// This function can be accessed by anyone
    public entry fun create_index_with_init_value(
        owner_signer: &signer,
        pair_ids: vector<u32>,
        weights: vector<u32>,
        init_value: u32,
    ) acquires IndexManager {
        // The length of both parameters should be the same
        assert!(vector::length(&pair_ids) == vector::length(&weights), error::invalid_argument(EMISSING_LENGTH));

        let init_value = (init_value as u256) * utils::calculate_power(10, MAX_INDEX_DECIMAL);
        let (scaling_factor, latest_pair_update_time) = init_value_scaling_factor(pair_ids, weights, init_value);
        create_index_helper(owner_signer, pair_ids, weights, init_value, scaling_factor, latest_pair_update_time);
    }

    /// Public entry function to update an existing index
    /// This function can be accessed those who owns index_id ownership
    public entry fun update_index(
        owner_signer: &signer,
        index_object: Object<Index>,
        pair_ids: vector<u32>,
        weights: vector<u32>,
    ) acquires Index {
        // The length of both parameters should be the same
        assert!(vector::length(&pair_ids) == vector::length(&weights), error::invalid_argument(EMISSING_LENGTH));
        utils::ensure_object_owner(index_object, owner_signer);

        let index_obj_addr = object::object_address(&index_object);
        let index = borrow_global_mut<Index>(index_obj_addr);
        let scaled_weights = scale_weights_to_target_initial_value(weights, index.scaling_factor);

        index.pair_ids = pair_ids;
        index.scaled_weights = scaled_weights;

        let update_index_time = timestamp::now_microseconds() / MILLISECOND_CONVERSION_FACTOR;
        // Emit the event for Update index
        event::emit(UpdateIndex { id: index.id, pair_ids, weights, update_index_time, scaled_weights, index_obj_addr });
    }

    /// Public entry function to delete an existing index
    /// This function can be accessed by those who owns index_id ownership
    public entry fun delete_index(
        owner_signer: &signer,
        index_object: Object<Index>,
    ) acquires IndexManager, Index {
        utils::ensure_object_owner(index_object, owner_signer);

        // Delete Index from the object
        let index_obj_addr = object::object_address(&index_object);
        let index = move_from<Index>(index_obj_addr);

        // Delete ObjectController from the table
        let index_manager = borrow_global_mut<IndexManager>(get_index_manager_address());
        let ObjectController { delete_ref, extend_ref: _, transfer_ref: _, object_addr: _ } = table::remove(
            &mut index_manager.index_map,
            index.id
        );

        // Delete ObjectCore
        object::delete(delete_ref);

        let delete_index_time = timestamp::now_microseconds() / MILLISECOND_CONVERSION_FACTOR;
        // Emit the event for Delete index
        event::emit(DeleteIndex { id: index.id, delete_index_time, index_obj_addr });
    }

    /// Public function to calculate the value of an index.
    /// This function can be accessed by anyone.
    public fun calculate_index_value(
        index_objects: vector<Object<Index>>,
    ): vector<u256> acquires Index {
        let index;
        let index_value;
        let latest_pair_update_time;

        let index_ids = vector[];
        let index_value_list = vector[];
        let calculate_index_time = vector[];
        let index_obj_addrs = vector[];

        vector::for_each_reverse(index_objects, |index_object| {
            let index_obj_addr = object::object_address(&index_object);
            index = borrow_global_mut<Index>(index_obj_addr);

            (index_value, latest_pair_update_time) = compute_index_value(index);

            // Update index_value only if the pair value is latest, otherwise skip it
            if (latest_pair_update_time > index.last_update_time) {
                index.index_value = index_value;
                index.last_update_time = latest_pair_update_time;
                vector::push_back(&mut index_value_list, index_value);
                vector::push_back(&mut index_ids, index.id);
                vector::push_back(&mut calculate_index_time, latest_pair_update_time);
                vector::push_back(&mut index_obj_addrs, index_obj_addr);
            };
        });
        vector::reverse(&mut index_value_list);

        // Emit the event for Calculate Index
        event::emit(CalculateIndex { ids: index_ids, index_value_list, calculate_index_time, index_obj_addrs });
        index_value_list
    }

    /// Public function that retrieves the index values considering staleness tolerance.
    /// If an index is stale, it recalculates and updates the value.
    /// - Returns `(vector<u256>, vector<bool>)`: A tuple containing two vectors:
    ///   - The first vector contains the index values (u256).
    ///   - The second vector contains boolean values indicating whether the index value is within the staleness tolerance (true).
    ///     If an index is stale, it recalculates, and still not within the tolerance, it returns (false).
    public fun get_indices_with_staleness_tolerance(
        index_objects: vector<Object<Index>>,
        staleness_tolerances: vector<u64>
    ): (vector<u256>, vector<bool>) acquires Index {
        // Ensure the length of index_objects and staleness_tolerances are the same
        assert!(
            vector::length(&index_objects) == vector::length(&staleness_tolerances),
            error::invalid_argument(EMISSING_LENGTH)
        );

        let index_ids = vector[];
        let index_value_list = vector[];
        let calculate_index_time = vector[];
        let index_obj_addrs = vector[];

        // Vector to store the final return values and staleness status
        let return_index_values = vector[];
        let return_index_staleness_status = vector[];

        // Process each index object with its corresponding staleness tolerance
        vector::zip(index_objects, staleness_tolerances, |index_object, staleness_tolerance| {
            let index_obj_addr = object::object_address(&index_object);
            let index = borrow_global_mut<Index>(index_obj_addr);
            let current_time = timestamp::now_microseconds() / MILLISECOND_CONVERSION_FACTOR;

            assert!(current_time > staleness_tolerance, error::out_of_range(EOUT_OF_CURRENT_TIME_RANGE));

            // If the index is stale, recalculate the value
            if (index.last_update_time < (current_time - staleness_tolerance)) {
                let (index_value, latest_pair_update_time) = compute_index_value(index);

                if (latest_pair_update_time > index.last_update_time) {
                    // Update the index with the new value and time
                    index.index_value = index_value;
                    index.last_update_time = latest_pair_update_time;

                    // Collect information for event emission
                    vector::push_back(&mut index_value_list, index_value);
                    vector::push_back(&mut index_ids, index.id);
                    vector::push_back(&mut calculate_index_time, latest_pair_update_time);
                    vector::push_back(&mut index_obj_addrs, index_obj_addr);

                    vector::push_back(&mut return_index_staleness_status, true);
                } else {
                    vector::push_back(&mut return_index_staleness_status, false);
                };

                // Add the updated value to the return list
                vector::push_back(&mut return_index_values, index_value);
            } else {
                // If not stale, add the existing value to the return list
                vector::push_back(&mut return_index_values, index.index_value);
                vector::push_back(&mut return_index_staleness_status, true);
            }
        });

        // Emit the event if there were any recalculations
        if (!vector::is_empty(&index_value_list)) {
            event::emit(CalculateIndex { ids: index_ids, index_value_list, calculate_index_time, index_obj_addrs });
        };

        (return_index_values, return_index_staleness_status)
    }

    #[view]
    /// Public view function to get `IndexManager` object address
    public fun get_index_manager_address(): address {
        object::create_object_address(&@supra_oracle, INDEX_MANAGER_SEED)
    }

    #[view]
    /// Public view function to get the details of index by there index_id
    public fun get_index_by_id(index_id: u64): Object<Index> acquires IndexManager {
        object::address_to_object<Index>(get_index_address(index_id))
    }

    #[view]
    /// Public view function to get `Index` object address from index_id
    public fun get_index_address(index_id: u64): address acquires IndexManager {
        let index_manager = borrow_global<IndexManager>(get_index_manager_address());
        ensure_index_exist(index_manager, index_id);
        table::borrow(&index_manager.index_map, index_id).object_addr
    }

    #[view]
    /// Get index object with details
    public fun get_index_details(index_object: Object<Index>): Index acquires Index {
        let index_address = object::object_address(&index_object);
        *borrow_global<Index>(index_address)
    }

    #[view]
    /// Get Weight of Index with `MAX_INDEX_DECIMAL` decimal
    public fun get_index_weight(index_id: u64): (vector<u256>, u16) acquires IndexManager, Index {
        let index_object = get_index_by_id(index_id);
        let index = *borrow_global<Index>(object::object_address(&index_object));
        let weights = vector::map(index.scaled_weights, |scaled_weight| {
            ((scaled_weight * utils::calculate_power(10, MAX_INDEX_DECIMAL)) / index.scaling_factor)
        });
        (weights, MAX_INDEX_DECIMAL)
    }

    #[test_only]
    fun add_test_pairs_data(supra_oracle: &signer) {
        supra_oracle_storage::create_oracle_holder_for_test(supra_oracle);
        supra_oracle_storage::add_pair_data_for_test(0, 2000000000000000000, 18, 400, 1);
        supra_oracle_storage::add_pair_data_for_test(1, 3000000000000000000, 18, 400, 1);
        supra_oracle_storage::add_pair_data_for_test(2, 5000000000000000000, 18, 400, 1);
    }

    #[test_only]
    fun update_pair_data_and_timestamp() {
        supra_oracle_storage::add_pair_data_for_test(0, 2000000000000000000, 18, 450, 2);
        supra_oracle_storage::add_pair_data_for_test(1, 3000000000000000000, 18, 450, 2);
        supra_oracle_storage::add_pair_data_for_test(2, 5000000000000000000, 18, 450, 2);
    }

    #[test]
    fun test_scale_weights_to_target_initial_value() {
        let result = scale_weights_to_target_initial_value(vector[40, 55], 50000);
        // 40 * 50000 = 2000000 & 55 * 50000 = 2750000
        assert!(result == vector[2000000, 2750000], 1);
    }

    #[test(supra_framework = @supra_framework, supra_oracle = @supra_oracle)]
    fun test_compute_weighted_pair_sum(supra_framework: &signer, supra_oracle: &signer) {
        timestamp::set_time_has_started_for_testing(supra_framework);
        add_test_pairs_data(supra_oracle);

        let (sum, _) = compute_weighted_pair_sum(vector[0, 1], vector[40, 55]);
        // (2 * 40) + (3 * 55) = 245 * 10^MAX_INDEX_DECIMAL
        assert!(sum == 245000000000000000000, 2)
    }

    #[test(supra_framework = @supra_framework, supra_oracle = @supra_oracle)]
    fun test_init_value_scaling_factor(supra_framework: &signer, supra_oracle: &signer) {
        timestamp::set_time_has_started_for_testing(supra_framework);
        add_test_pairs_data(supra_oracle);

        let (scaling_factor, _) = init_value_scaling_factor(vector[0, 1], vector[40, 55], 100 * utils::calculate_power(10, MAX_INDEX_DECIMAL));
        // sum = 245, so 100 * 10^MAX_INDEX_DECIMAL * 10^MAX_INDEX_DECIMAL / 245 * 10^MAX_INDEX_DECIMAL = 408163265306122448
        assert!(scaling_factor == 408163265306122448, 4);
    }

    #[test(supra_framework = @supra_framework, supra_oracle = @supra_oracle)]
    fun test_get_pair_value_with_scaled_weight(supra_framework: &signer, supra_oracle: &signer) {
        timestamp::set_time_has_started_for_testing(supra_framework);
        add_test_pairs_data(supra_oracle);

        // without MAX_INDEX_DECIMAL
        let (pair_index_value, _) = get_pair_value_with_scaled_weight(0, 35);
        // 2*10^decimal * 35 / 10^decimal
        assert!(pair_index_value == 70, 5);

        // with MAX_INDEX_DECIMAL
        let (pair_index_value, _) = get_pair_value_with_scaled_weight(0, 35000000000000000000);
        // 2*10^decimal * 35*10^MAX_INDEX_DECIMAL / 10^decimal
        assert!(pair_index_value == 70000000000000000000, 5);
    }

    #[test(supra_framework = @supra_framework, supra_oracle = @supra_oracle)]
    fun test_create_index(
        supra_framework: &signer,
        supra_oracle: &signer
    ) acquires IndexManager, Index {
        timestamp::set_time_has_started_for_testing(supra_framework);
        add_test_pairs_data(supra_oracle);
        init_module(supra_oracle);

        create_index(supra_oracle, vector[0, 1], vector[40, 60]);
        let index = borrow_global<Index>(get_index_address(1));
        assert!(index.id == 1, 1);

        create_index_with_init_value(supra_oracle, vector[1, 2], vector[30, 45], 100);
        let index = borrow_global<Index>(get_index_address(2));
        assert!(index.id == 2, 1);
        let (weight, decimal) = get_index_weight(2);
        assert!(weight == vector[30000000000000000000, 45000000000000000000], 5);
        assert!(decimal == MAX_INDEX_DECIMAL, 6);
    }

    #[test(supra_framework = @supra_framework, supra_oracle = @supra_oracle)]
    fun test_update_index(
        supra_framework: &signer,
        supra_oracle: &signer
    ) acquires IndexManager, Index {
        timestamp::set_time_has_started_for_testing(supra_framework);
        add_test_pairs_data(supra_oracle);
        init_module(supra_oracle);

        create_index_with_init_value(supra_oracle, vector[0, 1], vector[40, 60], 100);

        let (index_weight, decimal) = get_index_weight(1);
        assert!(index_weight == vector[40000000000000000000, 60000000000000000000], 5);
        assert!(decimal == MAX_INDEX_DECIMAL, 6);

        let index_object = get_index_by_id(1);
        update_index(supra_oracle, index_object, vector[0, 1], vector[30, 45]);
        let index = borrow_global<Index>(get_index_address(1));
        assert!(index.scaled_weights == vector[11538461538461538450, 17307692307692307675], 4);

        let (index_weight, decimal) = get_index_weight(1);
        assert!(index_weight == vector[30000000000000000000, 45000000000000000000], 5);
        assert!(decimal == MAX_INDEX_DECIMAL, 6);
    }

    #[test(supra_framework = @supra_framework, supra_oracle = @supra_oracle)]
    fun test_delete_index(
        supra_framework: &signer,
        supra_oracle: &signer
    ) acquires IndexManager, Index {
        timestamp::set_time_has_started_for_testing(supra_framework);
        add_test_pairs_data(supra_oracle);
        init_module(supra_oracle);

        create_index(supra_oracle, vector[0, 1], vector[40, 60]);
        let index = borrow_global<Index>(get_index_address(1));
        assert!(index.id == 1, 1);
        assert!(index.id == 1, 5);

        delete_index(supra_oracle, get_index_by_id(1));
        let index_manager = borrow_global<IndexManager>(get_index_manager_address());
        assert!(!table::contains(&index_manager.index_map, 1), 6);
    }

    #[test(supra_framework = @supra_framework, supra_oracle = @supra_oracle)]
    fun test_calculate_index_value(
        supra_framework: &signer,
        supra_oracle: &signer
    ) acquires IndexManager, Index {
        timestamp::set_time_has_started_for_testing(supra_framework);
        add_test_pairs_data(supra_oracle);
        init_module(supra_oracle);

        create_index(supra_oracle, vector[0, 1], vector[40, 60]);
        create_index_with_init_value(supra_oracle, vector[1, 2], vector[30, 45], 100);

        let index_object1 = get_index_by_id(1);
        let index_object2 = get_index_by_id(2);

        update_pair_data_and_timestamp();
        let indices = calculate_index_value( vector[index_object1, index_object2]);
        assert!(indices == vector[260000000000000000000, 99999999999999999900], 8);
    }

    #[test(supra_framework = @supra_framework, supra_oracle = @supra_oracle)]
    fun test_get_indices_with_staleness_tolerance(
        supra_framework: &signer,
        supra_oracle: &signer
    ) acquires IndexManager, Index {
        timestamp::set_time_has_started_for_testing(supra_framework);
        timestamp::update_global_time_for_test_secs(500);
        add_test_pairs_data(supra_oracle);
        init_module(supra_oracle);

        create_index(supra_oracle, vector[0, 1], vector[40, 60]);
        create_index_with_init_value(supra_oracle, vector[1, 2], vector[30, 45], 100);

        let index_object1 = get_index_by_id(1);
        let index_object2 = get_index_by_id(2);

        // update only pair index 0 value
        supra_oracle_storage::add_pair_data_for_test(0, 2000000000000000000, 18, 450, 2);

        let (indices, flags) = get_indices_with_staleness_tolerance(vector[index_object1, index_object2], vector[40, 40]);
        assert!(indices == vector[260000000000000000000, 99999999999999999900], 8);
        assert!(flags == vector[true, false], 9);

    }
}
