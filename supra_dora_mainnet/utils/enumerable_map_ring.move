module supra_utils::enumerable_map_ring {
    use std::vector;
    use aptos_std::table;
    use std::error;

    /// Key is already present in the map
    const EKEY_ALREADY_ADDED: u64 = 201;
    /// Key is absent in the map
    const EKEY_ABSENT: u64 = 202;
    /// Vector length mismatch
    const ELENGTH_MISMATCH: u64 = 203;


    struct EnumerableMapRing<K : copy + drop,V : store+drop+copy> has store {
        list: vector<K>, // list of all elements
        map: table::Table<K, Tuple<V>>,  // element mapped to a tuple containing the (position of key in list and value corresponding to the key)
        pointer: u64, // current position in vector where the new data will get inserted
        window_size: u64, // length of the list
    }

    struct Tuple<V : store+drop+copy> has store,copy,drop {
        position: u64,
        value: V,
    }

    struct KeyValue<K : copy + drop,V : store+drop+copy> has store,copy,drop {
        key: K,
        value: V,
    }

    /// To create an empty enum map ring
    public fun new_map<K : copy + drop,V : store+drop+copy>(window_size: u64): EnumerableMapRing<K,V>{
        return  EnumerableMapRing<K,V> {list : vector::empty<K>(), map: table::new<K,Tuple<V>>(), pointer:0,window_size}
    }

    /// Add Single Key in the Enumerable Map
    public fun add_value<K : copy+drop,V : store+drop+copy >(map: &mut EnumerableMapRing<K,V>, key: K,value: V) {
        assert!(!contains(map, key), error::already_exists(EKEY_ALREADY_ADDED));
        table::add(&mut map.map,key,Tuple<V>{position:map.pointer,value});
        if(vector::length(&map.list)== map.window_size ) {
            let current_stale_value = vector::borrow_mut(&mut map.list,map.pointer);
            table::remove(&mut map.map, *current_stale_value);
            *current_stale_value = key;
        }
        else{
            vector::push_back(&mut map.list,key);
        };
        map.pointer = (map.pointer+1) % map.window_size;

    }

    /// Add Multiple Keys in the Enumerable Map
    public fun add_value_bulk<K: copy+drop,V :store+drop+copy>(map: &mut EnumerableMapRing<K,V>,keys:vector<K>, values: vector<V>) {

        assert!(!vector::is_empty(&values), error::invalid_argument(EKEY_ABSENT));
        assert!(vector::length(&keys)==vector::length(&values),error::invalid_argument(ELENGTH_MISMATCH));

        vector::zip(keys,values, |key,value| {
            if(!contains(map,key)){
                add_value(map,key,value);
            }
        });

    }

    /// Update the value of already containsing key
    public fun update_value<K: copy+drop,V : store+drop+copy>(map: &mut EnumerableMapRing<K,V> , key: K, new_value: V): KeyValue<K,V> {
        assert!(contains(map,key),error::not_found(EKEY_ABSENT));
        table::borrow_mut(&mut map.map, key).value = new_value;
        KeyValue { key, value:new_value }

    }

    /// Clear all data present in the enum map
    public fun clear<K: copy+drop,V : store+drop+copy>(map: &mut EnumerableMapRing<K,V>) {
        while (!vector::is_empty(&map.list)) {
            let value = vector::pop_back(&mut map.list);
            table::remove(&mut map.map, value);
        }
    }

    /// Check Key contains or not
    public fun contains<K: copy+drop,V : store+drop+copy>(map: & EnumerableMapRing<K,V>, key: K): bool {
        table::contains(&map.map, key)
    }

    /// Returns the current stale value if the map length is window_size  else returns default value
    public fun get_stale_value<K: copy+drop,V : store+drop+copy>(map: & EnumerableMapRing<K,V>, default_key: K, default_value: V): KeyValue<K,V> {
        if(vector::length(&map.list) != map.window_size) {
            KeyValue{key: default_key, value:default_value}
        }
        else {
            let key = *vector::borrow(& map.list, map.pointer);
            let value = table::borrow(& map.map, key).value;
            KeyValue{key,value}
        }
    }

    /// Returns the value of a key that is present in Enumerable Map Ring
    public fun get_value<K : copy+drop, V : store+drop+copy>(map: & EnumerableMapRing<K,V>, key:K, default_value:V): V {
        if(contains(map,key)){
            table::borrow(&map.map,key).value
        }
        else {
            default_value
        }

    }

    /// Return current length of the EnumerableMapRing
    public fun length<K : copy+drop, V : store+drop+copy>(set: &EnumerableMapRing<K,V>): u64 {
        return vector::length(&set.list)
    }

    /// Returns the list of keys that the Enumerable Map Ring contains
    public fun ennumerable_map_ring_list<K : copy+drop, V : store+drop+copy>(map: &EnumerableMapRing<K,V>): vector<K> {
        return map.list
    }


    #[test_only]
    struct EnumerableMapTest<K: copy + drop,V : store+drop+copy> has key {
        e: EnumerableMapRing<K,V>
    }

    #[test(owner=@0x1111)]
    public fun test_add_value(owner:&signer) {
        let enum_map = new_map<u256,u256>(6);
        add_value(&mut enum_map,1,1);
        add_value(&mut enum_map,2,2);
        add_value(&mut enum_map,3,3);
        add_value(&mut enum_map,4,4);
        add_value(&mut enum_map,5,5);
        add_value(&mut enum_map,6,6);
        assert!(contains(& enum_map,3),1);
        assert!(length(& enum_map)==6,2);
        move_to(owner,EnumerableMapTest{e:enum_map})
    }

    #[test(owner=@0x1111)]
    public fun test_add_value_bulk(owner:&signer) {
        let enum_map = new_map<u256,u256>(5);
        add_value_bulk(&mut enum_map,vector[1,2,3,4,5,6,7,8,9],vector[1,2,3,4,5,6,7,8,9]);
        assert!(contains(& enum_map,8),1);
        assert!(length(& enum_map)==5,2);
        move_to(owner,EnumerableMapTest{e:enum_map});
    }

    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 1, location = Self)]
    public fun test_fail_add_value(owner:&signer) {
        let enum_map = new_map<u256,u256>(5);

        add_value(&mut enum_map,1,1);
        add_value(&mut enum_map,2,2);
        add_value(&mut enum_map,3,3);
        add_value(&mut enum_map,4,4);
        add_value(&mut enum_map,5,5);
        add_value(&mut enum_map,6,6);
        assert!(contains(& enum_map,1),1);
        assert!(length(& enum_map)==5,2);
        move_to(owner,EnumerableMapTest{e:enum_map})
    }
    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 1, location = Self)]
    public fun test_fail_add_value_bulk(owner:&signer) {
        let enum_map = new_map<u256,u256>(5);
        add_value_bulk(&mut enum_map,vector[1,2,3,4,5,6,7,8,9],vector[1,2,3,4,5,6,7,8,9]);
        assert!(contains(& enum_map,1),1);
        assert!(length(& enum_map)==5,2);
        move_to(owner,EnumerableMapTest{e:enum_map});
    }

    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 2, location = Self)]
    public fun test_fail_add_value_bulk_2(owner:&signer) {
        let enum_map = new_map<u256,u256>(5);
        add_value_bulk(&mut enum_map,vector[1,2,3,4,5,6,7,8,9],vector[1,2,3,4,5,6,7,8,9]);
        assert!(contains(& enum_map,9),1);
        assert!(length(& enum_map)==9,2);
        move_to(owner,EnumerableMapTest{e:enum_map});
    }

    #[test(owner=@0x1111)]
    public fun test_stale_value_check(owner:&signer) {
        let enum_map = new_map<u256,u256>(5);


        add_value_bulk(&mut enum_map,vector[1,2,3,4,5,6,7],vector[1,2,3,4,5,6,7]);
        assert!(get_stale_value(& enum_map,8,8).key == 3,1);
        assert!(length(& enum_map)==5,2);
        move_to(owner,EnumerableMapTest{e:enum_map})
    }



    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 3, location = Self)]
    public fun test_update_value(owner:&signer) {
        let enum_map = new_map<u256,u256>(5);
        add_value(&mut enum_map,1,1);
        add_value(&mut enum_map,2,2);
        add_value(&mut enum_map,3,3);
        add_value(&mut enum_map,4,4);
        add_value(&mut enum_map,5,5);
        add_value(&mut enum_map,6,6);
        update_value(&mut enum_map,4,7);
        assert!(contains(& enum_map,4),1);
        assert!(length(& enum_map)==5,2);
        assert!(get_value(& enum_map,1,0)==4,3);
        move_to(owner,EnumerableMapTest{e:enum_map})
    }

    #[test(owner=@0x1111)]
    public fun test_clear(owner:&signer) {
        let enum_map = new_map<u256,u256>(5);

        add_value(&mut enum_map,1,1);
        add_value(&mut enum_map,2,2);
        add_value(&mut enum_map,3,3);
        add_value(&mut enum_map,4,4);
        add_value(&mut enum_map,5,5);
        add_value(&mut enum_map,6,6);
        clear(&mut enum_map);
        assert!(length(& enum_map)==0,2);
        move_to(owner,EnumerableMapTest{e:enum_map})
    }
}