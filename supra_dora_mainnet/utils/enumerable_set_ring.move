module supra_utils::enumerable_set_ring {
    use std::vector;
    use aptos_std::table;
    use std::error;

    /// Pair is argument is empty
    const EVECTOR_EMPTY: u64 = 401;
    /// Value is already present in the set
    const EVALUE_ALREADY_ADDED: u64 = 402;

    /// Structure for a Enumerable Set
    struct EnumerableSetRing<T: copy + drop> has store {
        list: vector<T>, // list of all data points
        map: table::Table<T, u64>,  // data point mapped to the position in the vector
        pointer: u64, // current position in vector where the value will get inserted
        window_size: u64, // length of the list
    }

    /// Create an empty Enumerable Set
    public fun new_set<T: copy + drop>(window_size: u64):EnumerableSetRing<T>{
        return EnumerableSetRing<T> {list : vector::empty<T>(), map: table::new<T,u64>(), pointer : 0,window_size}
    }


    /// Add Single value from the Enumerable Set
    public fun push_value<T: copy + drop>(set: &mut EnumerableSetRing<T>, value: T) {

        assert!(!contains(set, value), error::already_exists(EVALUE_ALREADY_ADDED));

        table::add(&mut set.map, value, set.pointer);
        if(vector::length(&set.list)== set.window_size ) {
            let current_stale_value = vector::borrow_mut(&mut set.list,set.pointer);
            table::remove(&mut set.map, *current_stale_value);
            *current_stale_value = value;
        }
        else{
            vector::push_back(&mut set.list,value);
        };
        set.pointer = (set.pointer+1) % set.window_size;

    }

    /// Add Multiple values in the Enumerable Set
    public fun push_value_bulk<T: copy + drop>(set: &mut EnumerableSetRing<T>,  values: vector<T>) {

        assert!(!vector::is_empty(&values), error::invalid_argument(EVECTOR_EMPTY));
        vector::for_each(values, |value| {
            push_value(set,value);
        });

    }

    /// Clear all data present in the enum set
    public fun clear<T: copy + drop>(set: &mut EnumerableSetRing<T>) {
        while (!vector::is_empty(&set.list)) {
            let value = vector::pop_back(&mut set.list);
            table::remove(&mut set.map, value);
        }
    }


    /// Check value contains or not
    public fun contains<T : copy + drop>(set: & EnumerableSetRing<T>, value: T): bool {
        table::contains(&set.map, value)
    }

    /// Returns the current stale value if the set length is window_size else returns default value
    public fun get_stale_value<T : copy + drop>(set: & EnumerableSetRing<T>, default_value: T): T {
        if(vector::length(&set.list) != set.window_size) {
            default_value
        }
        else {
            *vector::borrow(& set.list, set.pointer)
        }
    }

    /// Returns all the elements from the set
    public fun ennumerable_set_list<T: copy + drop>(set: &EnumerableSetRing<T>): vector<T> {
        return set.list
    }

    /// Return current length of the EnumerableSetRing
    public fun length<T: copy + drop>(set: &EnumerableSetRing<T>): u64 {
        return vector::length(&set.list)
    }


    #[test_only]
    struct EnumerableSetTest<V : store+drop+copy> has key {
        e: EnumerableSetRing<V>
    }

    #[test(owner=@0x1111)]
    public fun test_push_value(owner:&signer) {
        let enum_set = new_set<u256>(6);
        push_value(&mut enum_set,1);
        push_value(&mut enum_set,2);
        push_value(&mut enum_set,3);
        push_value(&mut enum_set,4);
        push_value(&mut enum_set,5);
        push_value(&mut enum_set,6);
        push_value(&mut enum_set,7);
        push_value(&mut enum_set,8);
        assert!(contains(& enum_set,3),1);
        assert!(length(& enum_set)==6,2);
        move_to(owner,EnumerableSetTest{e:enum_set})
    }

    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 2, location = Self)]
    public fun test_fail_push_value(owner:&signer) {
        let enum_set = new_set<u256>(6);
        push_value(&mut enum_set,1);
        push_value(&mut enum_set,2);
        push_value(&mut enum_set,3);
        push_value(&mut enum_set,4);
        assert!(contains(& enum_set,3),1);
        assert!(length(& enum_set)==6,2);
        move_to(owner,EnumerableSetTest{e:enum_set})
    }

    #[test(owner=@0x1111)]
    public fun test_push_value_bulk(owner:&signer) {
        let enum_set = new_set<u256>(5);
        push_value_bulk(&mut enum_set,vector[1,2,3,4,5,6,7,8,9]);
        assert!(contains(& enum_set,8),1);
        assert!(length(& enum_set)==5,2);
        move_to(owner,EnumerableSetTest{e:enum_set});
    }

    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 1, location = Self)]
    public fun test_fail_push_value_bulk(owner:&signer) {
        let enum_set = new_set<u256>(5);
        push_value_bulk(&mut enum_set,vector[1,2,3,4,5,6,7,8,9]);
        assert!(contains(& enum_set,1),1);
        assert!(length(& enum_set)==5,2);
        move_to(owner,EnumerableSetTest{e:enum_set});
    }

    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 2, location = Self)]
    public fun test_fail_push_value_bulk_2(owner:&signer) {
        let enum_set = new_set<u256>(5);
        push_value_bulk(&mut enum_set,vector[1,2,3,4,5,6,7,8,9]);
        assert!(contains(& enum_set,9),1);
        assert!(length(& enum_set)==9,2);
        move_to(owner,EnumerableSetTest{e:enum_set});
    }

    #[test(owner=@0x1111)]
    public fun test_stale_value_check(owner:&signer) {
        let enum_set = new_set<u256>(5);

        push_value(&mut enum_set,1);
        push_value(&mut enum_set,2);
        push_value(&mut enum_set,3);
        push_value(&mut enum_set,4);
        push_value(&mut enum_set,5);
        push_value(&mut enum_set,6);
        assert!(get_stale_value(& enum_set,3) == 2,1);
        assert!(length(& enum_set)==5,2);
        move_to(owner,EnumerableSetTest{e:enum_set})
    }

    #[test(owner=@0x1111)]
    public fun test_clear(owner:&signer) {
        let enum_set = new_set<u256>(5);
        push_value(&mut enum_set,1);
        push_value(&mut enum_set,2);
        push_value(&mut enum_set,3);
        push_value(&mut enum_set,4);
        push_value(&mut enum_set,5);
        push_value(&mut enum_set,6);
        clear(&mut enum_set);
        assert!(length(& enum_set)==0,2);
        move_to(owner,EnumerableSetTest{e:enum_set})
    }


}