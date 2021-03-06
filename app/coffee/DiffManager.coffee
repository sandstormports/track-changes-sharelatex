UpdatesManager = require "./UpdatesManager"
DocumentUpdaterManager = require "./DocumentUpdaterManager"
DiffGenerator = require "./DiffGenerator"
logger = require "logger-sharelatex"

module.exports = DiffManager =
	getLatestDocAndUpdates: (project_id, doc_id, fromVersion, toVersion, callback = (error, content, version, updates) ->) ->
		UpdatesManager.getDocUpdatesWithUserInfo project_id, doc_id, from: fromVersion, to: toVersion, (error, updates) ->
			return callback(error) if error?
			DocumentUpdaterManager.getDocument project_id, doc_id, (error, content, version) ->
				return callback(error) if error?
				callback(null, content, version, updates)
	
	getDiff: (project_id, doc_id, fromVersion, toVersion, callback = (error, diff) ->) ->
		logger.log project_id: project_id, doc_id: doc_id, from: fromVersion, to: toVersion, "getting diff"
		DiffManager.getDocumentBeforeVersion project_id, doc_id, fromVersion, (error, startingContent, updates) ->
			return callback(error) if error?

			updatesToApply = []
			for update in updates.slice().reverse()
				if update.v <= toVersion
					updatesToApply.push update

			try
				diff = DiffGenerator.buildDiff startingContent, updatesToApply
			catch e
				return callback(e)
			
			callback(null, diff)

	getDocumentBeforeVersion: (project_id, doc_id, version, callback = (error, document, rewoundUpdates) ->) ->
		logger.log project_id: project_id, doc_id: doc_id, version: version, "getting document before version"
		DiffManager.getLatestDocAndUpdates project_id, doc_id, version, null, (error, content, version, updates) ->
			return callback(error) if error?

			lastUpdate = updates[0]
			if lastUpdate? and lastUpdate.v != version - 1
				return callback new Error("latest update version, #{lastUpdate.v}, does not match doc version, #{version}")

			try
				startingContent = DiffGenerator.rewindUpdates content, updates.slice().reverse()
			catch e
				return callback(e)
			
			callback(null, startingContent, updates)