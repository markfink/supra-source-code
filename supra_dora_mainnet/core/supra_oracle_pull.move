/// Pull Model:  This module provides functionality for pulling and verifying price data and extracting relevant information.
/// Action:
/// User: The User can access `verify_oracle_proof` and `price_data_split` function
module supra_oracle::supra_oracle_pull {

    use std::error;
    use std::vector;
    use aptos_std::aptos_hash::keccak256;
    use supra_framework::object;
    use supra_framework::multisig_account;
    use supra_utils::bcs;
    use supra_utils::merkle_tree;
    use supra_utils::utils;
    use supra_utils::enumerable_set_ring::{Self, EnumerableSetRing};
    use supra_oracle::supra_oracle_storage;
    use supra_oracle::supra_oracle_verifier;




    /// Capacity of the Ring Buffer
    const HASH_BUFFER_SIZE: u64 = 500;

    /// Signature verification failed
    const EINVALID_SIGNATURE: u64 = 100;
    /// Multileaf Merkle proof verification failed
    const EINVALID_MERKLE_PROOF: u64 = 101;
    /// Invalid Multisig account
    const EINVALID_MULTISIG_ACCOUNT: u64 = 102;

    /// Defined Oracle seeds that are used for creating resources
    const SEED_MERKLE_ROOT: vector<u8> = b"supra_oracle_pull::MerkleRootHash";

    /// Represents price data with information about the pair, price, decimal, timestamp
    struct PriceData has copy, drop {
        pair_index: u32,
        value: u128,
        timestamp: u64,
        decimal: u16,
        round: u64
    }

    struct CommitteeFeedWithMultileafProof has drop {
        committee_feeds: vector<PriceData>,
        // Multileaf merkle proof for the `committee_feeds`
        proofs: vector<vector<u8>>,
        flags: vector<bool>
    }

    struct PriceDetailsWithCommitteeData has drop {
        committee_id: u64,
        // root hash of the entire merkle tree used for committee_feed and committee_id verification
        root: vector<u8>,
        // signature can be verified for root and use committee_id indexed pub key for verification
        sig: vector<u8>,
        // typically contains all prices for committee_id
        committee_data: CommitteeFeedWithMultileafProof
    }

    struct OracleProof has drop {
        // each element of `data` contains one or more price-pairs emanating from a multiple committees
        data: vector<PriceDetailsWithCommitteeData>,
    }


    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct MerkleRootObjectController has key {
        transfer_ref: object::TransferRef,
        extend_ref: object::ExtendRef,
    }

    #[resource_group_member(group = supra_framework::object::ObjectGroup)]
    struct MerkleRootHash has key, store {
        // mapping of root hash with the timestamp of chain
        root_hashes: EnumerableSetRing<vector<u8>>
    }

    /// Its Initial function which will be executed automatically while deployed packages
    fun init_module(owner_signer: &signer) {
        let cons_ref = object::create_named_object(owner_signer,SEED_MERKLE_ROOT);
        let object_signer = object::generate_signer(&cons_ref);
        move_to(&object_signer,MerkleRootObjectController{transfer_ref:object::generate_transfer_ref(&cons_ref),extend_ref:object::generate_extend_ref(&cons_ref)});
        move_to(&object_signer, MerkleRootHash { root_hashes: enumerable_set_ring::new_set(HASH_BUFFER_SIZE) });
    }

    entry fun migrate_to_multisig(owner_signer: &signer, multisig_address:address) acquires MerkleRootObjectController {
        assert!(
            multisig_account::num_signatures_required(multisig_address) >= 2,
            error::invalid_state(EINVALID_MULTISIG_ACCOUNT)
        );
        let merkle_root_address = get_merkle_root_addr();
        utils::ensure_object_owner(object::address_to_object<MerkleRootObjectController>(merkle_root_address),owner_signer);
        let object_controller = borrow_global_mut<MerkleRootObjectController>(merkle_root_address);
        let linear_transfer_ref = object::generate_linear_transfer_ref(&object_controller.transfer_ref);
        object::transfer_with_ref(linear_transfer_ref,multisig_address);
    }

    /// Extracts relevant information from a PriceData struct
    public fun price_data_split(price_data: &PriceData): (u32, u128, u64, u16, u64) {
        (price_data.pair_index, price_data.value, price_data.timestamp, price_data.decimal, price_data.round)
    }

    /// Verifies the oracle proof and retrieves price data
    public fun verify_oracle_proof(
        _account: &signer,
        oracle_proof_bytes: vector<u8>
    ): vector<PriceData> acquires MerkleRootHash {
        let oracle_proof = decode_bytes_to_oracle_proof(oracle_proof_bytes);
        let merkle_root = borrow_global_mut<MerkleRootHash>(get_merkle_root_addr());

        let sign_result = vector::all(&oracle_proof.data, | data | {
            let data: &PriceDetailsWithCommitteeData = data; // annotating here, otherwise it will failed

            // Check if the root has been verified earlier. If not, we need to perform verification first. Otherwise, we can skip the verification
            if (!enumerable_set_ring::contains(&merkle_root.root_hashes, data.root)) {
                enumerable_set_ring::push_value(&mut merkle_root.root_hashes, data.root);
                supra_oracle_verifier::committee_sign_verification(data.committee_id, data.root, data.sig)
            } else {
                true
            }
        });
        assert!(sign_result, error::unauthenticated(EINVALID_SIGNATURE));

        let price_datas = vector[];
        while (!vector::is_empty(&oracle_proof.data)) {
            let data = vector::pop_back(&mut oracle_proof.data);
            let leaves = vector::map(data.committee_data.committee_feeds, |committee_feed| {
                keccak256(bcs::to_bytes(&committee_feed))
            });

            assert!(
                merkle_tree::is_valid_multileaf_merkle_proof(data.committee_data.proofs, data.committee_data.flags, leaves, data.root),
                EINVALID_MERKLE_PROOF
            );

            vector::for_each_reverse<PriceData>(data.committee_data.committee_feeds, |committee_feed| {
                let committee_feed:PriceData= committee_feed;
                // Update the pair data in storage if it's latest
                supra_oracle_storage::get_oracle_holder_and_upsert_pair_data(
                    committee_feed.pair_index,
                    committee_feed.value,
                    committee_feed.decimal,
                    committee_feed.timestamp,
                    committee_feed.round
                );

                // get the latest pair data from oracleholder object
                let pair_index = committee_feed.pair_index;
                let (value, decimal, timestamp, round) = supra_oracle_storage::get_price(pair_index);
                vector::push_back(
                    &mut price_datas,
                    PriceData { pair_index, value, timestamp: (timestamp as u64), decimal, round }
                );
            });
        };
        price_datas
    }

    /// This function will convert bytes into `OracleProof` type
    fun decode_bytes_to_oracle_proof(bytes: vector<u8>): OracleProof {
        let bcs_bytes = bcs::new(bytes);
        let data_len = bcs::peel_vec_length(&mut bcs_bytes);

        let data = vector[];
        while (data_len > 0) {
            let committee_id = bcs::peel_u64(&mut bcs_bytes);
            let root = bcs::peel_vec_u8(&mut bcs_bytes);
            let sig = bcs::peel_vec_u8(&mut bcs_bytes);
            let committee_feeds = vector[];

            let committee_feed_len = bcs::peel_vec_length(&mut bcs_bytes);
            while (committee_feed_len > 0) {
                let pair_index = bcs::peel_u32(&mut bcs_bytes);
                let value = bcs::peel_u128(&mut bcs_bytes);
                let timestamp = bcs::peel_u64(&mut bcs_bytes);
                let decimal = bcs::peel_u16(&mut bcs_bytes);
                let round = bcs::peel_u64(&mut bcs_bytes);
                vector::push_back(&mut committee_feeds, PriceData { pair_index, value, timestamp, decimal, round });
                committee_feed_len = committee_feed_len - 1;
            };
            let proofs = bcs::peel_vec_vec_u8(&mut bcs_bytes);

            let flags = vector[];
            let flag_len = bcs::peel_vec_length(&mut bcs_bytes);
            while (flag_len > 0) {
                let flag = bcs::peel_bool(&mut bcs_bytes);
                vector::push_back(&mut flags, flag);
                flag_len = flag_len - 1;
            };

            merkle_tree::ensure_multileaf_merkle_proof_lengths(proofs, flags, committee_feeds);

            let committee_data = CommitteeFeedWithMultileafProof { committee_feeds, proofs, flags };
            let price_detail_with_committee = PriceDetailsWithCommitteeData { committee_id, root, sig, committee_data };
            vector::push_back(&mut data, price_detail_with_committee);
            data_len = data_len - 1;
        };
        OracleProof { data }
    }

    #[view]
    /// Length of the MerkleRootHashes
    public fun merkle_root_hashes_length(): u64 acquires MerkleRootHash {
        enumerable_set_ring::length(&borrow_global<MerkleRootHash>(get_merkle_root_addr()).root_hashes)
    }

    #[view]
    /// to get object address of MerkleRootHash and MerkleRootObjectController easily
    public fun get_merkle_root_addr(): address {
        object::create_object_address(&@supra_oracle, SEED_MERKLE_ROOT)
    }

    #[test_only]
    fun oracle_proof_data_for_test(): OracleProof {
        OracleProof {
            data: vector[
                PriceDetailsWithCommitteeData {
                    committee_id: 0,
                    root: x"05bac7f141c89e1e90cd4919ac3588a8262b93882b3c33ab728f5cfa27a6011c",
                    sig: x"b19639266e09083443d636276c33f7820ab0e30d39e906fa368f767ca5e48b88925b2d38b230b6514cec2950e3d8d2dd13238c2c8ec639794eb48ebc16fed7a0e80a26c64c573456e9af87b8caef24252a2f191cffe15cddd62a5e5dbb9bfbb0",
                    committee_data: CommitteeFeedWithMultileafProof {
                        committee_feeds: vector[PriceData {
                            pair_index: 0,
                            value: 0,
                            timestamp: 2,
                            decimal: 18,
                            round: 2
                        }, PriceData {
                            pair_index: 1,
                            value: 1,
                            timestamp: 2,
                            decimal: 18,
                            round: 2
                        }
                        ],
                        proofs: vector[
                            x"95e4f2a5d8d98e0efa2c78b69ac8579e92bd6b56f65617c5de39c79a7c511da7",
                            x"a6639215fdadc344f39220d771d31374c04373f18d0c242cbdcdc4b56f4fc185"
                        ],
                        flags: vector[ true, false, false ]
                    },
                },
                PriceDetailsWithCommitteeData {
                    committee_id: 1,
                    root: x"d0c0446e059fe4ae1651180a4e68ea4c4749a58f7730d57ced200e2c8a627cc6",
                    sig: x"b8001d88d20b3455bbb61000d1c0bec980f1ad60c6c084bc4421138ef63ec95f277f1bae0bd7911604c093cf7d277a3406b0d6f5780449353ae87beba1363f2007cb9d6db1b8ea951d8470bcae4b59c24eee2a4f5b549643a173cfe504a37739",
                    committee_data: CommitteeFeedWithMultileafProof {
                        committee_feeds: vector[PriceData {
                            pair_index: 2,
                            value: 0,
                            timestamp: 2,
                            decimal: 18,
                            round: 2
                        }, PriceData {
                            pair_index: 3,
                            value: 1,
                            timestamp: 2,
                            decimal: 18,
                            round: 2
                        }
                        ],
                        proofs: vector[
                            x"cde86a79d770a50fc217c4009f7f3033821e368dc2d47b0226f9abc2f75c12de",
                            x"48ad222cf241b2982e273c4549de0eab1d19b481a0d4ad7e63f30dda21a49c60"
                        ],
                        flags: vector[ true, false, false ]
                    },
                }
            ]
        }
    }

    #[test_only]
    fun test_add_verify_oracle_proof(
        client: &signer,
        supra_holder: &signer,
        multisigner: &signer,
    ) acquires MerkleRootHash {
        let committee_0_public_key = x"98fb3cbe8c93393d92d8c106c19788d80695a3af70d6537ee4b4973f9b3b1238c0264fe4e6dd3989932022ed96c875a3";
        let committee_1_public_key = x"a4772aee49b4f1fbf30b36a101dea307b71316226f772fada3ae547cb9793740c11893105286082536c46b3a1ac929bf";

        // store committee public keys on DKG resource
        supra_oracle_verifier::add_committee_public_key_for_test(multisigner, 0, committee_0_public_key);
        supra_oracle_verifier::add_committee_public_key_for_test(multisigner, 1, committee_1_public_key);

        let oracle_proof = oracle_proof_data_for_test();
        let bytes = bcs::to_bytes(&oracle_proof);

        // verify oracle proof and store the pair data
        supra_oracle_storage::create_oracle_holder_for_test(supra_holder);
        init_module(supra_holder);

        verify_oracle_proof(client, bytes);

        while (!vector::is_empty(&oracle_proof.data)) {
            let price_details_with_committee = vector::pop_back(&mut oracle_proof.data);

            vector::for_each_reverse(price_details_with_committee.committee_data.committee_feeds, |committee_feed| {
                let committee_feed:PriceData = committee_feed;

                // get price data from oracle_holder and match with the request payload
                let (price, decimal, timestamp, round) =
                    supra_oracle_storage::get_price(committee_feed.pair_index);
                assert!(committee_feed.value == price, 11);
                assert!(committee_feed.decimal == decimal, 12);
                assert!(committee_feed.timestamp== timestamp, 13);
                assert!(committee_feed.round == round, 14);
            });
        }
    }

    #[test(
        client = @0x12,
        supra_holder = @supra_oracle,
        supra_framework = @supra_framework
    )]
    fun test_verify_oracle_proof(
        client: &signer,
        supra_holder: &signer,
        supra_framework: &signer
    ) acquires MerkleRootHash {
        supra_framework::timestamp::set_time_has_started_for_testing(supra_framework);
        supra_oracle::supra_oracle_hcc::create_oracle_hcc_for_test(supra_holder);
        test_add_verify_oracle_proof(client, supra_holder, supra_holder);
    }
}
