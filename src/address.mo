import Blob "mo:base/Blob";
import Nat8 "mo:base/Nat8";
import Principal "mo:base/Principal";
import Array "mo:base/Array";
import Iter "mo:base/Iter";
import IT "mo:itertools/Iter";
import Nat "mo:base/Nat";

module {

    public func canister2subaccount(canister_id : Principal, sa_type : SubaccountType) : Blob {
        let can = Blob.toArray(Principal.toBlob(canister_id));
        let size = can.size();
        let pad_start = 32 - size - 1:Nat;
        var sa = Iter.toArray(IT.flattenArray<Nat8>([
            Array.tabulate<Nat8>(pad_start, func _ = 0),
            can,
            [Nat8.fromNat(size)]
            ]));

        if (sa_type == #call) {
            let va = Array.thaw<Nat8>(sa);
            va[0] := 1;
            sa := Array.freeze<Nat8>(va);
        };

        Blob.fromArray(sa);
    };

    public type SubaccountType = { #call; #refill };
    public func subaccount2canister(subaccount : [Nat8]) : ?(Principal, SubaccountType) {
        if (subaccount.size() != 32) return null;
        let sa_type : SubaccountType = if (subaccount[0] == 1) #call else #refill;
        let size = Nat8.toNat(subaccount[31]);
        if (size == 0 or size > 20) return null;
        let p = Principal.fromBlob(Blob.fromArray(Iter.toArray(Array.slice(subaccount, 31 - size:Nat, 31))));
        if (Principal.isAnonymous(p)) return null;
        if (Principal.toText(p).size() != 27) return null; // Is Canister
        ?(p, sa_type)
    };

}