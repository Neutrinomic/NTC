import ICRCLedger "mo:devefi-icrc-ledger";
import ICL "mo:devefi-icrc-ledger/icrc_ledger";
import IC "./services/ic";
import ICPLedger "mo:devefi-icp-ledger";
import Principal "mo:base/Principal";
import Account "mo:account";
import Debug "mo:base/Debug";
import Timer "mo:base/Timer";
import Blob "mo:base/Blob";
import Iter "mo:base/Iter";
import Array "mo:base/Array";
import Float "mo:base/Float";
import Nat "mo:base/Nat";
import Cycles "mo:base/ExperimentalCycles";
import BTree "mo:stableheapbtreemap/BTree";
import Nat64 "mo:base/Nat64";
import IT "mo:itertools/Iter";
import List "mo:base/List";
import Error "mo:base/Error";
import Nat8 "mo:base/Nat8";
import Time "mo:base/Time";
import Int "mo:base/Int";



actor class NTCminter() = this {

  
    let T = 1_000_000_000_000;
    let NTC_to_canister_fee = 1000_0000; // ~13 cents
    let NTC_ledger_id = "7dx3o-7iaaa-aaaal-qsrdq-cai";

    stable let NTC_mem_v1 = ICRCLedger.Mem.Ledger.V1.new();
    let NTC_ledger = ICRCLedger.Ledger<system>(NTC_mem_v1, NTC_ledger_id, #last, Principal.fromActor(this));

    private let ic : IC.Self = actor ("aaaaa-aa");

    type NTC2Can_request_shared = {
        amount : Nat;
        canister : Principal;
        retry : Nat;
        last_try : Nat64;
    };

    type NTC2Can_request = {
        amount : Nat;
        canister : Principal;
        var retry : Nat;
        var last_try : Nat64;
    };


    // Latest
    stable let NTC2Can = BTree.init<Nat64, NTC2Can_request>(?32); // 32 is the order, or the size of each BTree node


    private func canister2subaccount(canister_id : Principal) : Blob {
        let can = Blob.toArray(Principal.toBlob(canister_id));
        let size = can.size();
        let pad_start = 32 - size - 1:Nat;
        Blob.fromArray(Iter.toArray(IT.flattenArray<Nat8>([
            Array.tabulate<Nat8>(pad_start, func _ = 0),
            can,
            [Nat8.fromNat(size)]
            ])));
    };


    private func subaccount2canister(subaccount : [Nat8]) : ?Principal {
        if (subaccount.size() != 32) return null;
        let size = Nat8.toNat(subaccount[31]);
        if (size == 0 or size > 20) return null;
        let p = Principal.fromBlob(Blob.fromArray(Iter.toArray(Array.slice(subaccount, 31 - size:Nat, 31))));
        if (Principal.isAnonymous(p)) return null;
        if (Principal.toText(p).size() != 27) return null; 
        ?p
    };

   
    stable var unique_request_id : Nat32 = 0;
    let MAX_CYCLE_SEND_CALLS = 20;

    ignore Timer.recurringTimer<system>(
        #seconds(6),
        func() : async () {

            var processing = List.nil<(async (), Nat64, NTC2Can_request)>();
            var i = 0;
            let now = Nat64.fromNat(Int.abs(Time.now()));
            // Make it send MAX_CYCLE_SEND_CALLS requests at a time and then await all
            var last_tried_id : Nat64 = 0;
            label sendloop while (i < MAX_CYCLE_SEND_CALLS) { 
                let ?(id, request) = BTree.deleteMax<Nat64, NTC2Can_request>(NTC2Can, Nat64.compare) else break sendloop;
                if (request.last_try != 0 and (now - request.last_try < 300*1_000_000_000)) { // retry every 2 minutes
                    let new_id : Nat64 = ((id >> 32) / 2) << 32 | Nat64.fromNat32(unique_request_id);
                    ignore BTree.insert<Nat64, NTC2Can_request>(NTC2Can, Nat64.compare, new_id, request);
                    unique_request_id += 1;
                    if (id == last_tried_id) break sendloop;
                    last_tried_id := new_id;
                    continue sendloop;
                };
                let cycles_amount = request.amount * 1_00_00;
                Debug.print(debug_show({cycles_amount;id;request}));
                // If we don't have enough cycles, wait for the ICP to be burned. Make sure we don't delete requests.
                // If we don't have 20T inside canister skip, we need to keep a minimum
                if (Cycles.balance() < cycles_amount + 20*T) continue sendloop; 

                try {
                 processing := List.push(((with cycles = cycles_amount) ic.deposit_cycles({ canister_id = request.canister }), id, request), processing);
                } catch (e) {
                    Debug.print("Err before await" # Error.message(e));
                };
    
                i += 1;
            };

            label awaitreq for ((promise, id, req) in List.toIter(processing)) {
                // Await results of all promises
                try {
                    // Q: Can this even trap? When?
                    let _myrefill = await promise; // Await the promise to get the tick data
                } catch (_e) {
                    Debug.print(Error.message(_e));
                    // Q: If it traps, does it mean we are 100% sure the cycles didn't get sent?
                    // We readd it to the queue, but with a lower id
                    if (req.retry > 10) continue awaitreq;
                    let new_id : Nat64 = ((id >> 32) / 2) << 32 | Nat64.fromNat32(unique_request_id);
                    req.retry += 1;
                    req.last_try := Nat64.fromNat(Int.abs(Time.now()));
                    ignore BTree.insert<Nat64, NTC2Can_request>(NTC2Can, Nat64.compare, new_id, req);
                    unique_request_id += 1;
                };
            };

        },
    );



    NTC_ledger.onReceive(
        func(t) {
            // Strategy: Unlike TCycles ledger, we will retry refilling the canister
            // if it doesn't work, the NTC gets burned. No NTC is gets returned if the subaccount is not a valid canister.
            let ?minter = NTC_ledger.getMinter() else Debug.trap("Err getMinter not set");
            let ?subaccount = t.to.subaccount else return;

            // Here we can convert the subaccount to a canister and send cycles while burning the NTC
            // We are adding these requests to a queue
            if (t.amount < NTC_to_canister_fee * 2) {
                if (t.amount > NTC_ledger.getFee()*2) { // burn if between ledger fee and NTC_to_canister_fee
                    // Burn
                    ignore NTC_ledger.send({
                        to = #icrc(minter);
                        amount = t.amount;
                        from_subaccount = ?subaccount;
                        memo = null;
                    });
                }; // ignore smaller amounts
                return;
            };

            // We add them based on amount and request id so we can pick the largest requests first
            let id : Nat64 = ((Nat64.fromNat(t.amount) / 1_0000_0000) << 32) | Nat64.fromNat32(unique_request_id);
            let ?canister = subaccount2canister(Blob.toArray(subaccount)) else return;
            ignore BTree.insert<Nat64, NTC2Can_request>(
                NTC2Can,
                Nat64.compare,
                id,
                {
                    amount = t.amount - NTC_to_canister_fee;
                    canister = canister;
                    var retry = 0;
                    var last_try = 0;
                },
            );
            unique_request_id += 1;

            // Burn
            ignore NTC_ledger.send({
                to = #icrc(minter);
                amount = t.amount;
                from_subaccount = ?subaccount;
                memo = null;
            });
        }
    );

    public query func get_queue() : async [(Nat64, NTC2Can_request_shared)] {
        
        Array.map<(Nat64, NTC2Can_request), (Nat64, NTC2Can_request_shared)>(BTree.toArray(NTC2Can), func(x) {
            (x.0, {
                amount = x.1.amount;
                canister = x.1.canister;
                retry = x.1.retry;
                last_try = x.1.last_try;
            });
        });
    };

    public shared ({ caller }) func mint(to : Account.Account) : async () {

        // Here we accept native cycles to mint NTC
        let received = Cycles.accept<system>(Cycles.available());
        if (received < T / 100) Debug.trap("Minimum 0.01T");

        // Convert from 12 decimals to 8
        let amount = received / 1_00_00;

        // Mint
        ignore NTC_ledger.send({
            to = #icrc(to);
            amount = amount;
            from_subaccount = null;
            memo = ?canister2subaccount(caller);
        });

    };

    type Stats = {
        cycles : Nat;
    };

    public query func stats() : async Stats {
        {
            cycles = Cycles.balance();
        };
    };

    public query func get_account(canister_id : Principal) : async (Account.Account, Text, Principal) {
        let acc : Account.Account = {
            owner = Principal.fromActor(this);
            subaccount = ?canister2subaccount(canister_id);
        };
        let ?back = subaccount2canister(Blob.toArray(canister2subaccount(canister_id))) else Debug.trap("Has to be a canister");
        (
            acc,
            Account.toText(acc),
            back
        );
    }

};
