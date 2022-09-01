//
//  Created by Alex Vlasov.
//  Copyright © 2018 Alex Vlasov. All rights reserved.
//
//  Additions for new transaction types by Mark Loit 2022

import Foundation
import BigInt

///  Structure capable of carying the parameters for any transaction type.
///  while all fields in this struct are optional, they are not necessarily
///  optional for the type of transaction they apply to.
public struct EncodableTransaction {
    /// internal acccess only. The transaction envelope object itself that contains all the transaction data
    /// and type specific implementation
    internal var envelope: AbstractEnvelope

    /// storage container for additional metadata returned by the node
    /// when a transaction is decoded form a JSON stream
    public var meta: EthereumMetadata?

    // MARK: - Properties that always sends to a Node

    /// the address of the sender of the transaction recovered from the signature
    public var from: EthereumAddress? {
        guard let publicKey = self.recoverPublicKey() else { return nil }
        return Utilities.publicToAddress(publicKey)
    }

    /// the destination, or contract, address for the transaction
    public var to: EthereumAddress {
        get { return envelope.to }
        set { envelope.to = newValue }
    }

    /// signifies the transaction type that this payload is for
    /// indicates what fields should be populated.
    /// this should always be set to give an idea of what other fields to expect
    public var type: TransactionType { return envelope.type }

    /// the nonce for the transaction
    public var nonce: BigUInt {
        get { return envelope.nonce }
        set { envelope.nonce = newValue }
    }

    /// the chainId that transaction is targeted for
    /// should be set for all types, except some Legacy transactions (Pre EIP-155)
    /// will not have this set
    public var chainID: BigUInt?

    /// the native value of the transaction
    public var value: BigUInt

    /// any additional data for the transaction
    public var data: Data

    // MARK: - Properties transaction type related either sends to a node if exist

    /// the max number of gas units allowed to process this transaction
    public var gasLimit: BigUInt?

    /// the price per gas unit for the tranaction (Legacy and EIP-2930 only)
    public var gasPrice: BigUInt?

    /// the max base fee per gas unit (EIP-1559 only)
    /// this value must be >= baseFee + maxPriorityFeePerGas
    public var maxFeePerGas: BigUInt?

    /// the maximum tip to pay the miner (EIP-1559 only)
    public var maxPriorityFeePerGas: BigUInt?

    public var callOnBlock: BlockNumber?

    /// access list for contract execution (EIP-2930 and EIP-1559 only)
    public var accessList: [AccessListEntry]?

    // MARK: - Properties to contract encode/sign data only

    // signature data is read-only
    /// signature v component (read only)
    public var v: BigUInt { return envelope.v }
    /// signature r component (read only)
    public var r: BigUInt { return envelope.r }
    /// signature s component (read only)
    public var s: BigUInt { return envelope.s }

    /// the transaction hash
    public var hash: Data? {
        guard let encoded: Data = self.envelope.encode(for: .transaction) else { return nil }
        let hash = encoded.sha3(.keccak256)
        return hash
    }

    // FIXME: This should made private up to release
    public init() { preconditionFailure("Memberwise not supported") } // disable the memberwise initializer


    /// - Returns: a hash of the transaction suitable for signing
    public func hashForSignature() -> Data? {
        guard let encoded = self.envelope.encode(for: .signature) else { return nil }
        let hash = encoded.sha3(.keccak256)
        return hash
    }

    /// - Returns: the public key decoded from the signature data
    public func recoverPublicKey() -> Data? {
        guard let sigData = envelope.getUnmarshalledSignatureData() else { return nil }
        guard let vData = BigUInt(sigData.v).serialize().setLengthLeft(1) else { return nil }
        let rData = sigData.r
        let sData = sigData.s

        guard let signatureData = SECP256K1.marshalSignature(v: vData, r: rData, s: sData) else { return nil }
        guard let hash = hashForSignature() else { return nil }

        guard let publicKey = SECP256K1.recoverPublicKey(hash: hash, signature: signatureData) else { return nil }
        return publicKey
    }

    /// Signs the transaction
    /// - Parameters:
    ///   - privateKey: the private key to use for signing
    ///   - useExtraEntropy: boolean whether to use extra entropy when signing (default false)
    public mutating func sign(privateKey: Data, useExtraEntropy: Bool = false) throws {
        for _ in 0..<1024 {
            let result = self.attemptSignature(privateKey: privateKey, useExtraEntropy: useExtraEntropy)
            if result { return }
        }
        throw AbstractKeystoreError.invalidAccountError
    }

    // actual signing algorithm implementation
    private mutating func attemptSignature(privateKey: Data, useExtraEntropy: Bool = false) -> Bool {
        guard let hash = self.hashForSignature() else { return false }
        let signature = SECP256K1.signForRecovery(hash: hash, privateKey: privateKey, useExtraEntropy: useExtraEntropy)
        guard let serializedSignature = signature.serializedSignature else { return false }
        guard let unmarshalledSignature = SECP256K1.unmarshalSignature(signatureData: serializedSignature) else { return false }
        guard let originalPublicKey = SECP256K1.privateToPublic(privateKey: privateKey) else { return false }
        self.envelope.setUnmarshalledSignatureData(unmarshalledSignature)
        let recoveredPublicKey = self.recoverPublicKey()
        if !(originalPublicKey.constantTimeComparisonTo(recoveredPublicKey)) { return false }
        return true
    }

    /// clears the signature data
    public mutating func unsign() {
        self.envelope.clearSignatureData()
    }

    /// Descriptionconverts transaction to the new selected type
    /// - Parameter to: TransactionType to select what transaction type to convert to
    public mutating func migrate(to type: TransactionType) {
        if self.type == type { return }

        let newEnvelope = EnvelopeFactory.createEnvelope(type: type, to: self.envelope.to,
                                                         nonce: self.envelope.nonce, parameters: self.envelope.parameters)
        self.envelope = newEnvelope
    }

    /// Create a new EthereumTransaction from a raw stream of bytes from the blockchain
    public init?(rawValue: Data) {
        guard let env = EnvelopeFactory.createEnvelope(rawValue: rawValue) else { return nil }
        self.envelope = env
        value = 0
        data = Data()
    }

    /// - Returns: a raw bytestream of the transaction, encoded according to the transactionType
    public func encode(for type: EncodeType = .transaction) -> Data? {
        return self.envelope.encode(for: type)
    }
}

extension EncodableTransaction: Codable {
    enum CodingKeys: String, CodingKey {
        case type
        case from
        case to
        case nonce
        case chainID
        case value
        case data
        case gasLimit
        case gasPrice
        case maxFeePerGas
        case maxPriorityFeePerGas
        case accessList
    }

    /// initializer required to support the Decodable protocol
    /// - Parameter decoder: the decoder stream for the input data
    public init(from decoder: Decoder) throws {
        guard let env = try EnvelopeFactory.createEnvelope(from: decoder) else { throw Web3Error.dataError }
        self.envelope = env
        value = 0
        data = Data()

        // capture any metadata that might be present
        self.meta = try EthereumMetadata(from: decoder)
    }

    public func encode(to encoder: Encoder) throws {
        var containier = encoder.container(keyedBy: CodingKeys.self)
        try containier.encode(type.rawValue.hexString, forKey: .type)
        try containier.encode(to, forKey: .to)
        try containier.encode(nonce.hexString, forKey: .nonce)
        try containier.encode(chainID?.hexString, forKey: .chainID)
        try containier.encode(value.hexString, forKey: .value)
        try containier.encode(data.toHexString().addHexPrefix(), forKey: .data)
        try containier.encode(gasLimit?.hexString, forKey: .gasLimit)
        try containier.encode(gasPrice?.hexString, forKey: .gasPrice)
        try containier.encode(maxFeePerGas?.hexString, forKey: .maxFeePerGas)
        try containier.encode(maxPriorityFeePerGas?.hexString, forKey: .maxPriorityFeePerGas)
        try containier.encode(accessList, forKey: .accessList)
    }

}

extension EncodableTransaction: CustomStringConvertible {
    /// required by CustomString convertable
    /// returns a string description for the transaction and its data
    public var description: String {
        var toReturn = ""
        toReturn += "Transaction" + "\n"
        toReturn += String(describing: self.envelope)
        toReturn += "from: " + String(describing: self.from?.address)  + "\n"
        toReturn += "hash: " + String(describing: self.hash?.toHexString().addHexPrefix()) + "\n"
        return toReturn
    }
}

extension EncodableTransaction: APIRequestParameterType { }
