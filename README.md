## Summary

Solidity smart contract to coordinate signatories of a multisignature wallet to
make transactions and sign them together.

## Description

Building Cardano multisignature transaction can be a bit difficult because of the coordination
between the shared owners of the address. One needs to be able to submit the transaction that
needs to be signed and all signatories need to be able to retrieve the transaction and analyse it
so that they are confident they can sign the transaction safely.

Then all signatory needs to be able to submit the witnesses to the transaction and share it with
all the other participants so that they may reconstruct the finalised transaction with the
witnesses and verify its authenticity.

There are also security aspects to this as every time a transaction is signed the signature
reveals the public key associated with the account and the witness is then available to read to
everyone.