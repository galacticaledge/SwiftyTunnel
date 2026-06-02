//
//  Database.swift
//  SwiftEditSH
//
//  Created by Chris Rios on 6/1/26.
//

import Foundation
import SQLite

struct Host: Identifiable, Hashable {
    var id: Int64
    var name: String
    var address: String
    var user: String
    var password: String
}

class Database {
    var connection: Connection
    
    let hosts = Table("hosts")
    let id = SQLite.Expression<Int64>("id")
    let name = SQLite.Expression<String>("name")
    let address = SQLite.Expression<String>("address")
    let user = SQLite.Expression<String>("user")
    let password = SQLite.Expression<String>("password")
    
    init() throws {
        let fileManager = FileManager.default
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)
        
        let dbUrl = appSupport.appendingPathComponent("SESH.db")
        
        connection = try Connection(dbUrl.path)
        
        do {
            try createTable()
        } catch {
            throw error
        }
    }
    
    private func createTable() throws {
        try connection.run(hosts.create(ifNotExists: true) { t in
            t.column(id, primaryKey: true)
            t.column(name)
            t.column(address)
            t.column(user)
            t.column(password)
        })
    }
    
    public func getHosts() throws -> [Host] {
        try connection.prepare(hosts).map { row in
            Host(
                id: row[id],
                name: row[name],
                address: row[address],
                user: row[user],
                password: row[password]
            )
        }
    }
    
    public func addHost(host: Host) throws {
        let insert = hosts.insert(
            name <- host.name,
            address <- host.address,
            user <- host.user,
            password <- host.password
        )
        
        try connection.run(insert)
    }
    
    public func deleteHost(host: Host) throws {
        let host = hosts.filter(id == host.id)
        
        try! connection.run(host.delete())
    }
}
