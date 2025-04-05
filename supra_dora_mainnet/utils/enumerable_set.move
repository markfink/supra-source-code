module supra_utils::enumerable_set {
    use std::vector;
    use aptos_std::table;
    use std::error;

    /// Value is already present in the set
    const EVALUE_ALREADY_ADDED: u64 = 301;
    /// Value is not present in the set
    const EVALUE_ABSENT: u64 = 302;
    /// Pair is argument is empty
    const EVECTOR_EMPTY: u64 = 303;


    /// Structure for a Enumerable Set
    struct EnumerableSet<T: copy + drop> has store {
        list: vector<T>, // list of all data points
        map: table::Table<T, u64>,  // data point mapped to the position in the vector
    }

    /// Create a new Enumerable Set
    public fun new_set<T: copy + drop>():EnumerableSet<T>{
        return EnumerableSet<T> {list : vector::empty<T>(), map: table::new<T,u64>()}
    }


    /// Add Single value from the Enumerable Set
    public fun push_value<T: copy + drop>(set: &mut EnumerableSet<T>, value: T) {
        assert!(!contains(set, value), error::already_exists(EVALUE_ALREADY_ADDED));
        table::add(&mut set.map, value, vector::length(& set.list));
        vector::push_back(&mut set.list, value);

    }

    /// Add Multiple values in the Enumerable Set
    public fun push_value_bulk<T: copy + drop>(set: &mut EnumerableSet<T>,  values: vector<T>) : vector<T> {
        assert!(!vector::is_empty(&values), error::invalid_argument(EVECTOR_EMPTY));

        let list_length = vector::length(& set.list);
        let updated_values=vector::empty<T>();

        vector::for_each_reverse(values, |value| {
            if(!contains(set,value)){
                table::add(&mut set.map, value,list_length);
                vector::push_back(&mut set.list, value);
                list_length = list_length+1;
                vector::push_back(&mut updated_values, value);
            }
        });
        return updated_values
    }

    /// Remove single value from the Enumerable Set
    public fun pop_value<T: copy + drop>(set: &mut EnumerableSet<T>, value: T) {
        assert!(contains(set, value), error::not_found(EVALUE_ABSENT));

        let list_length = vector::length(& set.list);
        let index_of_value = table::borrow(&set.map,value);

        vector::swap(&mut set.list,*index_of_value, list_length-1);
        vector::pop_back(&mut set.list);
        * table::borrow_mut(&mut set.map,* vector::borrow(& set.list, *index_of_value)) = *index_of_value;
        table::remove(&mut set.map, value);

    }

    /// Remove Multiple values from the Enumerable Set
    public fun pop_value_bulk<T: copy + drop>(set: &mut EnumerableSet<T>,  values: vector<T>): vector<T> {
        assert!(!vector::is_empty(&values), error::invalid_argument(EVECTOR_EMPTY));

        let list_length = vector::length(& set.list);
        let removed_values=vector::empty<T>();

        vector::for_each_reverse(values, |value| {
            if (contains(set, value)) {
                let index_of_value = table::borrow(&mut set.map,value);
                list_length=list_length-1;
                vector::swap(&mut set.list,*index_of_value, list_length);
                * table::borrow_mut(&mut set.map,* vector::borrow(& set.list, *index_of_value)) = *index_of_value;
                vector::pop_back(&mut set.list);
                table::remove(&mut set.map, value);
                vector::push_back(&mut removed_values, value);
            };
        });

        return removed_values

    }

    /// Clears all the data points from the set
    public fun clear<T: copy + drop>(set: &mut EnumerableSet<T>) {
        let list = ennumerable_set_list(set);
        pop_value_bulk(set,list);
    }

    /// Returns all the elements from the set
    public fun ennumerable_set_list<T: copy + drop>(set: &EnumerableSet<T>): vector<T> {
        return set.list
    }

    /// Return current length of the EnumerableSetRing
    public fun length<T: copy + drop>(set: &EnumerableSet<T>): u64 {
        return vector::length(&set.list)
    }

    /// Check value contains or not
    public fun contains<T : copy + drop>(set: & EnumerableSet<T>, value: T): bool {
        table::contains(&set.map, value)
    }

    #[test_only]
    struct EnumerableSetTest<V : store+drop+copy> has key {
        e: EnumerableSet<V>
    }

    #[test(owner=@0x1111)]
    public fun test_push_value(owner:&signer) {
        let enum_set = new_set<u256>();
        push_value(&mut enum_set,1);
        push_value(&mut enum_set,2);
        push_value(&mut enum_set,3);
        push_value(&mut enum_set,4);
        push_value(&mut enum_set,5);
        push_value(&mut enum_set,6);
        assert!(contains(& enum_set,3),1);
        assert!(length(& enum_set)==6,2);
        move_to(owner,EnumerableSetTest{e:enum_set})
    }

    #[test(owner=@0x1111)]
    public fun test_push_value_bulk(owner:&signer) {
        let enum_set = new_set<u256>();
        push_value(&mut enum_set,1);
        push_value(&mut enum_set,2);
        push_value(&mut enum_set,3);
        push_value(&mut enum_set,4);
        push_value(&mut enum_set,5);
        push_value(&mut enum_set,6);
        push_value_bulk(&mut enum_set,vector[7,8,9]);
        assert!(contains(& enum_set,8),1);
        assert!(length(& enum_set)==9,2);
        move_to(owner,EnumerableSetTest{e:enum_set});
    }

    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 1, location = Self)]
    public fun test_pop_value(owner:&signer) {
        let enum_set = new_set<u256>();

        push_value(&mut enum_set,1);
        push_value(&mut enum_set,2);
        push_value(&mut enum_set,3);
        push_value(&mut enum_set,4);
        push_value(&mut enum_set,5);
        push_value(&mut enum_set,6);
        pop_value(&mut enum_set,1);
        pop_value(&mut enum_set,2);
        pop_value(&mut enum_set,3);
        assert!(contains(& enum_set,3),1);
        assert!(length(& enum_set)==3,2);
        move_to(owner,EnumerableSetTest{e:enum_set})
    }

    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 2, location = Self)]
    public fun test_remove_bulk_value(owner:&signer) {
        let enum_set = new_set<u256>();

        push_value(&mut enum_set,1);
        push_value(&mut enum_set,2);
        push_value(&mut enum_set,3);
        push_value(&mut enum_set,4);
        push_value(&mut enum_set,5);
        push_value(&mut enum_set,6);
        pop_value_bulk(&mut enum_set,vector[1,2,3]);
        assert!(contains(& enum_set,4),1);
        assert!(length(& enum_set)==6,2);
        move_to(owner,EnumerableSetTest{e:enum_set})
    }

    #[test(owner=@0x1111)]
    public fun test_clear(owner:&signer) {
        let enum_set = new_set<u256>();
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