module supra_utils::ring_buffer {

    use std::vector;
    use std::error;

    /// Pair is argument is empty
    const EVECTOR_EMPTY: u64 = 600;

    struct RingBuffer<T: copy + drop> has store,copy,drop {
        list: vector<T>, // Vector of T having window_soze as max length
        pointer: u64, // point to the List vector whose value needs to be changed
        window_size: u64, // length of the list
    }

    public fun new<T: copy + drop>(window_size: u64): RingBuffer<T> {
        return RingBuffer<T> {list: vector::empty<T>(), pointer: 0, window_size}
    }

    public fun push_value<T: copy + drop>(ring: &mut RingBuffer<T>, value: T) {
        if(vector::length(&ring.list)== ring.window_size ) {
            let current_stale_value = vector::borrow_mut(&mut ring.list,ring.pointer);
            *current_stale_value = value;
        }
        else{
            vector::push_back(&mut ring.list,value);
        };
        ring.pointer = (ring.pointer+1) % ring.window_size;
    }

    /// Add Multiple values in the Ring Buffer
    public fun push_value_bulk<T: copy + drop>(set: &mut RingBuffer<T>,  values: vector<T>) {

        assert!(!vector::is_empty(&values), error::invalid_argument(EVECTOR_EMPTY));
        vector::for_each(values, |value| {
            push_value(set,value);
        });

    }

    /// Returns the current stale value if the buffer length is window_size else returns default value
    public fun get_stale_value<T : copy + drop>(buffer: & RingBuffer<T>, default_value: T): T {
        if(vector::length(&buffer.list) != buffer.window_size) {
            default_value
        }
        else {
            *vector::borrow(& buffer.list, buffer.pointer)
        }
    }

    /// Returns the last value inserted if the buffer length is window_size else returns default value
    public fun get_value<T : copy + drop>(buffer: & RingBuffer<T>, default_value: T): T {
        if(vector::length(&buffer.list) == 0) {
            default_value
        }
        else if (buffer.pointer == 0) {
            *vector::borrow(& buffer.list, buffer.window_size-1)
        }
        else {
            *vector::borrow(& buffer.list, buffer.pointer-1)
        }
    }

    /// Clear all data present in the ring buffer
    public fun clear<T: copy + drop>(buffer: &mut RingBuffer<T>) {
        while (!vector::is_empty(&buffer.list)) {
            vector::pop_back(&mut buffer.list);
        }
    }

    /// Returns all the elements from the Ring buffer
    public fun ring_buffer_list<T: copy + drop>(buffer: &RingBuffer<T>): vector<T> {
        return buffer.list
    }

    /// Return current length of the Ring buffer
    public fun length<T: copy + drop>(buffer: &RingBuffer<T>): u64 {
        return vector::length(&buffer.list)
    }


    #[test_only]
    struct RingBufferTest<V : store+drop+copy> has key {
        e: RingBuffer<V>
    }

    #[test(owner=@0x1111)]
    public fun test_push_value(owner:&signer) {
        let ring_buffer = new<u256>(6);
        push_value(&mut ring_buffer,1);
        push_value(&mut ring_buffer,2);
        push_value(&mut ring_buffer,3);
        push_value(&mut ring_buffer,4);
        push_value(&mut ring_buffer,5);
        push_value(&mut ring_buffer,6);
        push_value(&mut ring_buffer,7);
        push_value(&mut ring_buffer,8);
        assert!(get_value(& ring_buffer,3) == 8,1);
        assert!(length(& ring_buffer)==6,2);
        move_to(owner,RingBufferTest{e:ring_buffer})
    }

    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 2, location = Self)]
    public fun test_fail_push_value(owner:&signer) {
        let ring_buffer = new<u256>(6);
        push_value(&mut ring_buffer,1);
        push_value(&mut ring_buffer,2);
        push_value(&mut ring_buffer,3);
        push_value(&mut ring_buffer,4);
        assert!(get_value(& ring_buffer,3) == 4,1);
        assert!(length(& ring_buffer)==6,2);
        move_to(owner,RingBufferTest{e:ring_buffer})
    }

    #[test(owner=@0x1111)]
    public fun test_push_value_bulk(owner:&signer) {
        let ring_buffer = new<u256>(5);
        push_value_bulk(&mut ring_buffer,vector[1,2,3,4,5,6,7,8,9]);
        assert!(get_value(& ring_buffer,0) == 9 ,1);
        assert!(length(& ring_buffer)==5,2);
        move_to(owner,RingBufferTest{e:ring_buffer});
    }

    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 1, location = Self)]
    public fun test_fail_push_value_bulk(owner:&signer) {
        let ring_buffer = new<u256>(5);
        push_value_bulk(&mut ring_buffer,vector[1,2,3,4,5,6,7,8,9]);
        assert!(get_value(& ring_buffer,0) == 1,1);
        assert!(length(& ring_buffer)==5,2);
        move_to(owner,RingBufferTest{e:ring_buffer});
    }

    #[test(owner=@0x1111)]
    #[expected_failure(abort_code = 2, location = Self)]
    public fun test_fail_push_value_bulk_2(owner:&signer) {
        let ring_buffer = new<u256>(5);
        push_value_bulk(&mut ring_buffer,vector[1,2,3,4,5,6,7,8,9]);
        assert!(get_value(& ring_buffer,0) == 9,1);
        assert!(length(& ring_buffer)==9,2);
        move_to(owner,RingBufferTest{e:ring_buffer});
    }

    #[test(owner=@0x1111)]
    public fun test_stale_value_check(owner:&signer) {
        let ring_buffer = new<u256>(5);

        push_value(&mut ring_buffer,1);
        push_value(&mut ring_buffer,2);
        push_value(&mut ring_buffer,3);
        push_value(&mut ring_buffer,4);
        push_value(&mut ring_buffer,5);
        push_value(&mut ring_buffer,6);
        assert!(get_stale_value(& ring_buffer,3) == 2,1);
        assert!(length(& ring_buffer)==5,2);
        move_to(owner,RingBufferTest{e:ring_buffer})
    }

    #[test(owner=@0x1111)]
    public fun test_clear(owner:&signer) {
        let ring_buffer = new<u256>(5);
        push_value(&mut ring_buffer,1);
        push_value(&mut ring_buffer,2);
        push_value(&mut ring_buffer,3);
        push_value(&mut ring_buffer,4);
        push_value(&mut ring_buffer,5);
        push_value(&mut ring_buffer,6);
        clear(&mut ring_buffer);
        assert!(length(& ring_buffer)==0,2);
        move_to(owner,RingBufferTest{e:ring_buffer})
    }
}
