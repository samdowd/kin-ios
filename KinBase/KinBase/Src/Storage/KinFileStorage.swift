//
//  KinFileStorage.swift
//  KinBase
//
//  Created by Kik Interactive Inc. on 2020-04-07.
//  Copyright © 2020 Kin Foundation. All rights reserved.
//

import Foundation
import Promises

public class KinFileStorage  {
    public enum Errors: Error {
        case unknown
        case malformattedInput
        case missingAccount
        case unregisteredAccount
    }

    private struct Constants {
        static let accountInfoFileName = "account_info"
        static let transactionsFileName = "transactions"
        static let minFeeUserDefaultsKey = "KinBase.MinFee"
    }

    private let fileManager = FileManager.default
    private let userDefaults = UserDefaults.standard
    private let rootDirectory: URL
    private let keyStore: SecureKeyStorage = KeyChainStorage()
    private let network: KinNetwork
    private let fileAccessQueue: DispatchQueue = DispatchQueue(label: "KinBase.KinFileStorage")

    /// - Parameters:
    ///   - directory: the directory where the storage locates, use document directory if icloud backup is desired
    ///   - network: the Kin network envrionment of the contents in this storage instance
    public init(directory: URL = URL(fileURLWithPath: NSTemporaryDirectory()),
                network: KinNetwork) {
        self.rootDirectory = directory
        self.network = network
    }
}

// MARK: Public - KinStorageType
extension KinFileStorage: KinStorageType {

    // MARK: Account Operations
    public func addAccount(_ account: KinAccount) throws -> KinAccount {
        try addKeyToSecureStore(accountId: account.id, key: account.key)
        try writeAccountInfo(account)
        return account
    }

    public func addAccount(_ account: KinAccount) -> Promise<KinAccount> {
        let promise = addKeyToSecureStoreAsync(accountId: account.id, key: account.key)
        return promise.then { [weak self] _ -> Promise<KinAccount> in
            guard let self = self else {
                return .init(Errors.unknown)
            }

            return self.writeAccountInfoAsync(account)
        }
    }

    public func getAccount(_ accountId: KinAccount.Id) -> Promise<KinAccount?> {
        let key = try? getKeyFromSecureStore(accountId: accountId)
        let account = readAccountInfoSync(accountId)
        return self.merge(key: key, with: account)
    }

    public func updateAccount(_ account: KinAccount) -> Promise<KinAccount> {
        return getAccount(account.id)
            .then { [weak self] storedAccount -> Promise<KinAccount> in
                guard let self = self else {
                    return .init(Errors.unknown)
                }

                guard let storedAccount = storedAccount else {
                    return self.addAccount(account)
                }

                let key = storedAccount.key.privateKey != nil ? storedAccount.key : account.key
                let updatedAccount = KinAccount(key: key,
                                                balance: account.balance,
                                                status: account.status,
                                                sequence: account.sequence)
                return self.addAccount(updatedAccount)
        }
    }

    public func removeAccount(accountId: KinAccount.Id) -> Promise<Void> {
        let promise = removeKeyFromSecureStore(accountId: accountId)
        return promise.then { [weak self] _ -> Promise<Void> in
            guard let self = self else {
                return .init(Errors.unknown)
            }

            let accountDirectory = self.directoryForAccount(accountId)
            return self.removeFileOrDirectory(accountDirectory)
        }
    }

    public func advanceSequence(accountId: KinAccount.Id) -> Promise<KinAccount> {
        return getAccount(accountId)
            .then { account -> Promise<KinAccount> in
                guard let account = account else {
                    return .init(Errors.missingAccount)
                }

                guard let sequence = account.sequence,
                    account.status == .registered
                    else {
                        return .init(Errors.unregisteredAccount)
                }

                let updatedAccount = KinAccount(key: account.key,
                                                balance: account.balance,
                                                status: account.status,
                                                sequence: sequence + 1)

                return self.updateAccount(updatedAccount)
        }
    }

    public func deductFromAccountBalance(accountId: KinAccount.Id,
                                         amount: Kin) -> Promise<KinAccount> {
        return getAccount(accountId)
            .then { account -> Promise<KinAccount> in
                guard let account = account else {
                    return .init(Errors.missingAccount)
                }

                guard account.status == .registered
                    else {
                        return .init(Errors.unregisteredAccount)
                }

                let deductedBalance = KinBalance(account.balance.amount - amount)
                let updatedAccount = KinAccount(key: account.key,
                                                balance: deductedBalance,
                                                status: account.status,
                                                sequence: account.sequence)

                return self.updateAccount(updatedAccount)
        }
    }

    public func getAllAccountIds() -> Promise<[KinAccount.Id]> {
        guard let contents = try? fileManager.contentsOfDirectory(at: directoryForAllAccounts,
                                                                  includingPropertiesForKeys: nil)
            else {
                return Promise([])
        }

        let promises = contents
            .map { $0.appendingPathComponent(Constants.accountInfoFileName)}
            .map { readAccountInfo($0) }

        return any(promises).then { accountsOrError in
            let accountIds = accountsOrError.compactMap { $0.value??.id }
            return Promise(accountIds)
        }
    }

    // MARK: Transaction Operations
    public func storeTransactions(accountId: KinAccount.Id,
                                  transactions: [KinTransaction]) -> Promise<[KinTransaction]> {
        var headPagingToken: KinTransaction.PagingToken?
        for item in transactions {
            if item.record.recordType == .historical {
                headPagingToken = item.record.pagingToken
                break
            }
        }

        var tailPagingToken: KinTransaction.PagingToken?
        for item in transactions.reversed() {
            if item.record.recordType == .historical {
                tailPagingToken = item.record.pagingToken
                break
            }
        }

        let kinTransactions = KinTransactions(items: transactions,
                                              headPagingToken: headPagingToken,
                                              tailPagingToken: tailPagingToken)
        return writeTransactions(accoutnId: accountId, transactions: kinTransactions)
    }

    public func getStoredTransactions(accountId: KinAccount.Id) -> Promise<KinTransactions?> {
        return readTransactions(accountId: accountId)
    }

    public func insertNewTransaction(accountId: KinAccount.Id,
                                     newTransaction: KinTransaction) -> Promise<[KinTransaction]> {
        return getStoredTransactions(accountId: accountId)
            .then { transactions -> [KinTransaction] in
                return transactions?.items ?? [] + [newTransaction]
            }
            .then { self.storeTransactions(accountId: accountId, transactions: $0) }
    }

    public func upsertNewTransactions(accountId: KinAccount.Id,
                                      newTransactions: [KinTransaction]) -> Promise<[KinTransaction]> {
        return getStoredTransactions(accountId: accountId)
            .then { transactions -> [KinTransaction] in
                var storedTransactions = transactions?.items ?? []
                storedTransactions = storedTransactions.filter { stored -> Bool in
                    return !newTransactions.contains { new -> Bool in
                        return new.transactionHash == stored.transactionHash
                    }
                }

                return newTransactions + storedTransactions
            }
            .then { self.storeTransactions(accountId: accountId, transactions: $0) }
    }

    public func upsertOldTransactions(accountId: KinAccount.Id,
                                      oldTransactions: [KinTransaction]) -> Promise<[KinTransaction]> {
        return getStoredTransactions(accountId: accountId)
        .then { transactions -> [KinTransaction] in
            var storedTransactions = transactions?.items ?? []
            storedTransactions = storedTransactions.filter { stored -> Bool in
                return !oldTransactions.contains { new -> Bool in
                    return new.transactionHash == stored.transactionHash
                }
            }

            return storedTransactions + oldTransactions
        }
        .then { self.storeTransactions(accountId: accountId, transactions: $0) }
    }

    public func setMinFee(_ fee: Quark) {
        userDefaults.set(fee, forKey: Constants.minFeeUserDefaultsKey)
    }

    public func getMinFee() -> Quark? {
        return userDefaults.value(forKey: Constants.minFeeUserDefaultsKey) as? Quark
    }

    public func clearStorage() -> Promise<Void> {
        userDefaults.removeObject(forKey: Constants.minFeeUserDefaultsKey)
        return removeFileOrDirectory(kinStorageDirectory)
    }
}

// MARK: Private - File Location
private extension KinFileStorage {
    var kinStorageDirectory: URL {
        return rootDirectory.appendingPathComponent("kin_storage", isDirectory: true)
    }

    var environmentDirectory: URL {
        return kinStorageDirectory
            .appendingPathComponent("env", isDirectory: true)
            .appendingPathComponent(network.id.base32HexEncodedString, isDirectory: true)
    }

    var directoryForAllAccounts: URL {
        return environmentDirectory.appendingPathComponent("kin_accounts", isDirectory: true)
    }

    func directoryForAccount(_ accountId: KinAccount.Id) -> URL {
        return directoryForAllAccounts.appendingPathComponent(String(accountId.hashValue), isDirectory: true)
    }

    func pathForAccountInfoFile(_ accountId: KinAccount.Id) -> URL {
        return directoryForAccount(accountId).appendingPathComponent(Constants.accountInfoFileName)
    }

    func pathForTransactionsFile(for accountId: KinAccount.Id) -> URL {
        return directoryForAccount(accountId).appendingPathComponent(Constants.transactionsFileName)
    }
}

// MARK: Private - Account Operations
private extension KinFileStorage {
    func writeAccountInfo(_ account: KinAccount) throws {
        guard let data = account.storableObject.data() else {
            throw Errors.malformattedInput
        }

        // Make sure directory exists
        let accountDirectory = directoryForAccount(account.id)
        try fileManager.createDirectory(at: accountDirectory,
                                        withIntermediateDirectories: true)

        let accountInfoFile = pathForAccountInfoFile(account.id)

        try data.write(to: accountInfoFile,
                       options: .atomic)
    }

    func writeAccountInfoAsync(_ account: KinAccount) -> Promise<KinAccount> {
        return Promise<KinAccount>.init(on: fileAccessQueue) { [weak self] fulfill, reject in
            guard let self = self else {
                reject(Errors.unknown)
                return
            }

            do {
                try self.writeAccountInfo(account)
                fulfill(account)
            } catch let error {
                reject(error)
            }
        }
    }

    func merge(key: KinAccount.Key?, with account: KinAccount?) -> Promise<KinAccount?> {
        return Promise<KinAccount?>.init(on: fileAccessQueue) { fulfill, reject in
            // If private key is stored, merge with account info, otherwise return an account without private key
            guard let account = account else {
                let unregistedAccount = key != nil ? KinAccount(key: key!) : nil
                fulfill(unregistedAccount)
                return
            }

            if let key = key {
                let mergedAccount = KinAccount(key: key,
                                               balance: account.balance,
                                               status: account.status,
                                               sequence: account.sequence)
                fulfill(mergedAccount)
                return
            }

            fulfill(account)
        }
    }

    func readAccountInfo(_ accountId: KinAccount.Id) -> Promise<KinAccount?> {
        let accountInfoFile = self.pathForAccountInfoFile(accountId)
        return readAccountInfo(accountInfoFile)
    }

    func readAccountInfo(_ filePath: URL) -> Promise<KinAccount?> {
        return Promise<KinAccount?>.init(on: fileAccessQueue) { fulfill, reject in
            do {
                guard let data = try? Data(contentsOf: filePath) else {
                    fulfill(nil)
                    return
                }

                let storageObject = try KinStorageKinAccount(data: data)
                let kinAccount = storageObject.kinAccount
                fulfill(kinAccount)

            } catch let error {
                reject(error)
            }
        }
    }

    func readAccountInfoSync(_ accountId: KinAccount.Id) -> KinAccount? {
        let accountInfoFile = pathForAccountInfoFile(accountId)
        return readAccountInfoSync(accountInfoFile)
    }

    func readAccountInfoSync(_ filePath: URL) -> KinAccount? {
        guard let data = try? Data(contentsOf: filePath) else {
            return nil
        }

        let storageObject = try? KinStorageKinAccount(data: data)
        return storageObject?.kinAccount
    }

    func writeTransactions(accoutnId: KinAccount.Id, transactions: KinTransactions) -> Promise<[KinTransaction]> {
        return Promise<[KinTransaction]>.init(on: fileAccessQueue) { [weak self] fulfill, reject in
            guard let self = self else {
                reject(Errors.unknown)
                return
            }

            guard let data = transactions.storableObject.data() else {
                reject(Errors.malformattedInput)
                return
            }

            do {
                // Make sure directory exists
                let accountDirectory = self.directoryForAccount(accoutnId)
                try self.fileManager.createDirectory(at: accountDirectory,
                                                     withIntermediateDirectories: true)

                let transactionsFile = self.pathForTransactionsFile(for: accoutnId)

                try data.write(to: transactionsFile,
                               options: .atomic)
                fulfill(transactions.items)
            } catch let error {
                reject(error)
            }
        }
    }

    func readTransactions(accountId: KinAccount.Id) -> Promise<KinTransactions?> {
        return Promise<KinTransactions?>.init(on: fileAccessQueue) { [weak self] fulfill, reject in
            guard let self = self else {
                reject(Errors.unknown)
                return
            }

            let transactionsFile = self.pathForTransactionsFile(for: accountId)

            guard let data = try? Data(contentsOf: transactionsFile) else {
                fulfill(nil)
                return
            }

            let storageObject = try KinStorageKinTransactions(data: data)
            let kinTransactions = storageObject.kinTransactions(network: self.network)
            fulfill(kinTransactions)
        }
    }

    func removeFileOrDirectory(_ url: URL) -> Promise<Void> {
        return Promise<Void>.init(on: fileAccessQueue) { [weak self] fulfill, reject in
            guard let self = self else {
                reject(Errors.unknown)
                return
            }

            do {
                if self.fileManager.fileExists(atPath: url.path) {
                    try self.fileManager.removeItem(at: url)
                }

                fulfill(())
            } catch let error {
                reject(error)
            }
        }
    }
}

// MARK: Private - Key Store Access
private extension KinFileStorage {
    func addKeyToSecureStore(accountId: KinAccount.Id, key: KinAccount.Key) throws {
        guard let secret = key.seed?.secret,
            let keyData = secret.data(using: .utf8) else {
            // No private key needs to be added
            return
        }

        try keyStore.add(account: accountId, key: keyData)
    }

    func addKeyToSecureStoreAsync(accountId: KinAccount.Id,
                             key: KinAccount.Key) -> Promise<Void> {
        return Promise<Void>.init(on: fileAccessQueue) { [weak self] fulfill, reject in
            guard let self = self else {
                reject(Errors.unknown)
                return
            }

            do {
                try self.addKeyToSecureStore(accountId: accountId, key: key)
                fulfill(())
            } catch let error {
                reject(error)
            }
        }
    }

    func getKeyFromSecureStore(accountId: KinAccount.Id) throws -> KinAccount.Key? {
        do {
            guard let secretData = keyStore.retrieve(account: accountId),
                let secret = String(bytes: secretData, encoding: .utf8) else {
                return nil
            }

            return try KinAccount.Key(secretSeed: secret)

        } catch let error {
            throw error
        }
    }

    func removeKeyFromSecureStore(accountId: KinAccount.Id) -> Promise<Void> {
        return Promise<Void>.init(on: fileAccessQueue) { [weak self] fulfill, reject in
            guard let self = self else {
                reject(Errors.unknown)
                return
            }

            do {
                try self.keyStore.delete(account: accountId)
                fulfill(())
            } catch let error {
                reject(error)
            }
        }
    }
}

