sinon = require('sinon')
chai = require('chai')
should = chai.should()
expect = chai.expect
modulePath = "../../../../app/js/UpdatesManager.js"
SandboxedModule = require('sandboxed-module')

describe "UpdatesManager", ->
	beforeEach ->
		@UpdatesManager = SandboxedModule.require modulePath, requires:
			"./UpdateCompressor": @UpdateCompressor = {}
			"./MongoManager" : @MongoManager = {}
			"./RedisManager" : @RedisManager = {}
			"./LockManager"  : @LockManager = {}
			"./WebApiManager": @WebApiManager = {}
			"./UpdateTrimmer": @UpdateTrimmer = {}
			"logger-sharelatex": { log: sinon.stub(), error: sinon.stub() }
		@doc_id = "doc-id-123"
		@project_id = "project-id-123"
		@callback = sinon.stub()
		@temporary = "temp-mock"

	describe "compressAndSaveRawUpdates", ->
		describe "when there are no raw ops", ->
			beforeEach ->
				@MongoManager.popLastCompressedUpdate = sinon.stub()
				@MongoManager.insertCompressedUpdates = sinon.stub()
				@UpdatesManager.compressAndSaveRawUpdates @project_id, @doc_id, [], @temporary, @callback

			it "should not need to access the database", ->
				@MongoManager.popLastCompressedUpdate.called.should.equal false
				@MongoManager.insertCompressedUpdates.called.should.equal false

			it "should call the callback", ->
				@callback.called.should.equal true

		describe "when there is no compressed history to begin with", ->
			beforeEach ->
				@rawUpdates = [{ v: 12, op: "mock-op-12" }, { v: 13, op: "mock-op-13" }]
				@compressedUpdates = { v: 13, op: "compressed-op-12" }

				@MongoManager.popLastCompressedUpdate = sinon.stub().callsArgWith(1, null, null)
				@MongoManager.insertCompressedUpdates = sinon.stub().callsArg(4)
				@UpdateCompressor.compressRawUpdates = sinon.stub().returns(@compressedUpdates)
				@UpdatesManager.compressAndSaveRawUpdates @project_id, @doc_id, @rawUpdates, @temporary, @callback

			it "should try to pop the last compressed op", ->
				@MongoManager.popLastCompressedUpdate
					.calledWith(@doc_id)
					.should.equal true
			
			it "should compress the raw ops", ->
				@UpdateCompressor.compressRawUpdates
					.calledWith(null, @rawUpdates)
					.should.equal true
			
			it "should save the compressed ops", ->
				@MongoManager.insertCompressedUpdates
					.calledWith(@project_id, @doc_id, @compressedUpdates, @temporary)
					.should.equal true

			it "should call the callback", ->
				@callback.called.should.equal true

		describe "when the raw ops need appending to existing history", ->
			beforeEach ->
				@lastCompressedUpdate = { v: 11, op: "compressed-op-11" }
				@compressedUpdates = { v: 13, op: "compressed-op-12" }

				@MongoManager.popLastCompressedUpdate = sinon.stub().callsArgWith(1, null, @lastCompressedUpdate)
				@MongoManager.insertCompressedUpdates = sinon.stub().callsArg(4)
				@UpdateCompressor.compressRawUpdates = sinon.stub().returns(@compressedUpdates)

			describe "when the raw ops start where the existing history ends", ->
				beforeEach ->
					@rawUpdates = [{ v: 12, op: "mock-op-12" }, { v: 13, op: "mock-op-13" }]
					@UpdatesManager.compressAndSaveRawUpdates @project_id, @doc_id, @rawUpdates, @temporary, @callback

				it "should try to pop the last compressed op", ->
					@MongoManager.popLastCompressedUpdate
						.calledWith(@doc_id)
						.should.equal true
				
				it "should compress the last compressed op and the raw ops", ->
					@UpdateCompressor.compressRawUpdates
						.calledWith(@lastCompressedUpdate, @rawUpdates)
						.should.equal true
				
				it "should save the compressed ops", ->
					@MongoManager.insertCompressedUpdates
						.calledWith(@project_id, @doc_id, @compressedUpdates, @temporary)
						.should.equal true

				it "should call the callback", ->
					@callback.called.should.equal true

			describe "when some raw ops are passed that have already been compressed", ->
				beforeEach ->
					@rawUpdates = [{ v: 10, op: "mock-op-10" }, { v: 11, op: "mock-op-11"}, { v: 12, op: "mock-op-12" }, { v: 13, op: "mock-op-13" }]

					@UpdatesManager.compressAndSaveRawUpdates @project_id, @doc_id, @rawUpdates, @temporary, @callback

				it "should only compress the more recent raw ops", ->
					@UpdateCompressor.compressRawUpdates
						.calledWith(@lastCompressedUpdate, @rawUpdates.slice(-2))
						.should.equal true

			describe "when the raw ops do not follow from the last compressed op version", ->
				beforeEach ->
					@rawUpdates = [{ v: 13, op: "mock-op-13" }]
					@UpdatesManager.compressAndSaveRawUpdates @project_id, @doc_id, @rawUpdates, @temporary, @callback

				it "should call the callback with an error", ->
					@callback
						.calledWith(new Error("Tried to apply raw op at version 13 to last compressed update with version 11"))
						.should.equal true

				it "should put the popped update back into mongo", ->
					@MongoManager.insertCompressedUpdates.calledOnce.should.equal true
					@MongoManager.insertCompressedUpdates
						.calledWith(@project_id, @doc_id, [@lastCompressedUpdate], @temporary)
						.should.equal true

	describe "processUncompressedUpdates", ->
		beforeEach ->
			@UpdatesManager.compressAndSaveRawUpdates = sinon.stub().callsArgWith(4)
			@RedisManager.deleteOldestRawUpdates = sinon.stub().callsArg(3)
			@MongoManager.backportProjectId = sinon.stub().callsArg(2)
			@UpdateTrimmer.shouldTrimUpdates = sinon.stub().callsArgWith(1, null, @temporary = "temp mock")

		describe "when there is fewer than one batch to send", ->
			beforeEach ->
				@updates = ["mock-update"]
				@RedisManager.getOldestRawUpdates = sinon.stub().callsArgWith(2, null, @updates)
				@UpdatesManager.processUncompressedUpdates @project_id, @doc_id, @callback

			it "should check if the updates are temporary", ->
				@UpdateTrimmer.shouldTrimUpdates
					.calledWith(@project_id)
					.should.equal true

			it "should backport the project id", ->
				@MongoManager.backportProjectId
					.calledWith(@project_id, @doc_id)
					.should.equal true

			it "should get the oldest updates", ->
				@RedisManager.getOldestRawUpdates
					.calledWith(@doc_id, @UpdatesManager.REDIS_READ_BATCH_SIZE)
					.should.equal true

			it "should compress and save the updates", ->
				@UpdatesManager.compressAndSaveRawUpdates
					.calledWith(@project_id, @doc_id, @updates, @temporary)
					.should.equal true

			it "should delete the batch of uncompressed updates that was just processed", ->
				@RedisManager.deleteOldestRawUpdates
					.calledWith(@project_id, @doc_id, @updates.length)
					.should.equal true

			it "should call the callback", ->
				@callback.called.should.equal true

		describe "when there are multiple batches to send", ->
			beforeEach (done) ->
				@UpdatesManager.REDIS_READ_BATCH_SIZE = 2
				@updates = ["mock-update-0", "mock-update-1", "mock-update-2", "mock-update-3", "mock-update-4"]
				@redisArray = @updates.slice()
				@RedisManager.getOldestRawUpdates = (doc_id, batchSize, callback = (error, updates) ->) =>
					updates = @redisArray.slice(0, batchSize)
					@redisArray = @redisArray.slice(batchSize)
					callback null, updates
				sinon.spy @RedisManager, "getOldestRawUpdates"
				@UpdatesManager.processUncompressedUpdates @project_id, @doc_id, (args...) =>
					@callback(args...)
					done()

			it "should get the oldest updates in three batches ", ->
				@RedisManager.getOldestRawUpdates.callCount.should.equal 3

			it "should compress and save the updates in batches", ->
				@UpdatesManager.compressAndSaveRawUpdates
					.calledWith(@project_id, @doc_id, @updates.slice(0,2), @temporary)
					.should.equal true
				@UpdatesManager.compressAndSaveRawUpdates
					.calledWith(@project_id, @doc_id, @updates.slice(2,4), @temporary)
					.should.equal true
				@UpdatesManager.compressAndSaveRawUpdates
					.calledWith(@project_id, @doc_id, @updates.slice(4,5), @temporary)
					.should.equal true

			it "should delete the batches of uncompressed updates", ->
				@RedisManager.deleteOldestRawUpdates.callCount.should.equal 3

			it "should call the callback", ->
				@callback.called.should.equal true

	describe "processCompressedUpdatesWithLock", ->
		beforeEach ->
			@UpdatesManager.processUncompressedUpdates = sinon.stub().callsArg(2)
			@LockManager.runWithLock = sinon.stub().callsArg(2)
			@UpdatesManager.processUncompressedUpdatesWithLock @project_id, @doc_id, @callback

		it "should run processUncompressedUpdates with the lock", ->
			@LockManager.runWithLock
				.calledWith(
					"HistoryLock:#{@doc_id}"
				)
				.should.equal true

		it "should call the callback", ->
			@callback.called.should.equal true

	describe "getDocUpdates", ->
		beforeEach ->
			@updates = ["mock-updates"]
			@options = { to: "mock-to", limit: "mock-limit" }
			@MongoManager.getDocUpdates = sinon.stub().callsArgWith(2, null, @updates)
			@UpdatesManager.processUncompressedUpdatesWithLock = sinon.stub().callsArg(2)
			@UpdatesManager.getDocUpdates @project_id, @doc_id, @options, @callback

		it "should process outstanding updates", ->
			@UpdatesManager.processUncompressedUpdatesWithLock
				.calledWith(@project_id, @doc_id)
				.should.equal true

		it "should get the updates from the database", ->
			@MongoManager.getDocUpdates
				.calledWith(@doc_id, @options)
				.should.equal true

		it "should return the updates", ->
			@callback
				.calledWith(null, @updates)
				.should.equal true

	describe "getDocUpdatesWithUserInfo", ->
		beforeEach ->
			@updates = ["mock-updates"]
			@options = { to: "mock-to", limit: "mock-limit" }
			@updatesWithUserInfo = ["updates-with-user-info"]
			@UpdatesManager.getDocUpdates = sinon.stub().callsArgWith(3, null, @updates)
			@UpdatesManager.fillUserInfo = sinon.stub().callsArgWith(1, null, @updatesWithUserInfo)
			@UpdatesManager.getDocUpdatesWithUserInfo @project_id, @doc_id, @options, @callback

		it "should get the updates", ->
			@UpdatesManager.getDocUpdates
				.calledWith(@project_id, @doc_id, @options)
				.should.equal true

		it "should file the updates with the user info", ->
			@UpdatesManager.fillUserInfo
				.calledWith(@updates)
				.should.equal true

		it "should return the updates with the filled details", ->
			@callback.calledWith(null, @updatesWithUserInfo).should.equal true

	describe "getProjectUpdates", ->
		beforeEach ->
			@updates = ["mock-updates"]
			@options = { before: "mock-before", limit: "mock-limit" }
			@MongoManager.getProjectUpdates = sinon.stub().callsArgWith(2, null, @updates)
			@UpdatesManager.processUncompressedUpdatesForProject = sinon.stub().callsArg(1)
			@UpdatesManager.getProjectUpdates @project_id, @options, @callback

		it "should process any outstanding updates", ->
			@UpdatesManager.processUncompressedUpdatesForProject
				.calledWith(@project_id)
				.should.equal true

		it "should get the updates from the database", ->
			@MongoManager.getProjectUpdates
				.calledWith(@project_id, @options)
				.should.equal true

		it "should return the updates", ->
			@callback
				.calledWith(null, @updates)
				.should.equal true

	describe "processUncompressedUpdatesForProject", ->
		beforeEach (done) ->
			@doc_ids = ["mock-id-1", "mock-id-2"]
			@UpdatesManager.processUncompressedUpdatesWithLock = sinon.stub().callsArg(2)
			@RedisManager.getDocIdsWithHistoryOps = sinon.stub().callsArgWith(1, null, @doc_ids)
			@UpdatesManager.processUncompressedUpdatesForProject @project_id, () =>
				@callback()
				done()

		it "should get all the docs with history ops", ->
			@RedisManager.getDocIdsWithHistoryOps
				.calledWith(@project_id)
				.should.equal true

		it "should process the doc ops for the each doc_id", ->
			for doc_id in @doc_ids
				@UpdatesManager.processUncompressedUpdatesWithLock
					.calledWith(@project_id, doc_id)
					.should.equal true

		it "should call the callback", ->
			@callback.called.should.equal true

	describe "getProjectUpdatesWithUserInfo", ->
		beforeEach ->
			@updates = ["mock-updates"]
			@options = { before: "mock-before", limit: "mock-limit" }
			@updatesWithUserInfo = ["updates-with-user-info"]
			@UpdatesManager.getProjectUpdates = sinon.stub().callsArgWith(2, null, @updates)
			@UpdatesManager.fillUserInfo = sinon.stub().callsArgWith(1, null, @updatesWithUserInfo)
			@UpdatesManager.getProjectUpdatesWithUserInfo @project_id, @options, @callback

		it "should get the updates", ->
			@UpdatesManager.getProjectUpdates
				.calledWith(@project_id, @options)
				.should.equal true

		it "should file the updates with the user info", ->
			@UpdatesManager.fillUserInfo
				.calledWith(@updates)
				.should.equal true

		it "should return the updates with the filled details", ->
			@callback.calledWith(null, @updatesWithUserInfo).should.equal true

	describe "_extendBatchOfSummarizedUpdates", ->
		beforeEach ->
			@before = Date.now()
			@min_count = 2
			@existingSummarizedUpdates = ["summarized-updates-3"]
			@summarizedUpdates = ["summarized-updates-3", "summarized-update-2", "summarized-update-1"]

		describe "when there are updates to get", ->
			beforeEach ->
				@updates = [
					{op: "mock-op-1", meta: end_ts: @before - 10},
					{op: "mock-op-1", meta: end_ts: @nextBeforeTimestamp = @before - 20}
				]
				@existingSummarizedUpdates = ["summarized-updates-3"]
				@summarizedUpdates = ["summarized-updates-3", "summarized-update-2", "summarized-update-1"]
				@UpdatesManager._summarizeUpdates = sinon.stub().returns(@summarizedUpdates)
				@UpdatesManager.getProjectUpdatesWithUserInfo = sinon.stub().callsArgWith(2, null, @updates)
				@UpdatesManager._extendBatchOfSummarizedUpdates @project_id, @existingSummarizedUpdates, @before, @min_count, @callback

			it "should get the updates", ->
				@UpdatesManager.getProjectUpdatesWithUserInfo
					.calledWith(@project_id, { before: @before, limit: 3 * @min_count })
					.should.equal true

			it "should summarize the updates", ->
				@UpdatesManager._summarizeUpdates
					.calledWith(@updates, @existingSummarizedUpdates)
					.should.equal true

			it "should call the callback with the summarized updates and the next before timestamp", ->
				@callback.calledWith(null, @summarizedUpdates, @nextBeforeTimestamp).should.equal true

		describe "when there are no more updates", ->
			beforeEach ->
				@updates = []
				@UpdatesManager._summarizeUpdates = sinon.stub().returns(@summarizedUpdates)
				@UpdatesManager.getProjectUpdatesWithUserInfo = sinon.stub().callsArgWith(2, null, @updates)
				@UpdatesManager._extendBatchOfSummarizedUpdates @project_id, @existingSummarizedUpdates, @before, @min_count, @callback

			it "should call the callback with the summarized updates and null for nextBeforeTimestamp", ->
				@callback.calledWith(null, @summarizedUpdates, null).should.equal true

	describe "getSummarizedProjectUpdates", ->
		describe "when one batch of updates is enough to meet the limit", ->
			beforeEach ->
				@before = Date.now()
				@min_count = 2
				@updates = ["summarized-updates-3", "summarized-updates-2"]
				@nextBeforeTimestamp = @before - 100
				@UpdatesManager._extendBatchOfSummarizedUpdates = sinon.stub().callsArgWith(4, null, @updates, @nextBeforeTimestamp)
				@UpdatesManager.getSummarizedProjectUpdates @project_id, { before: @before, min_count: @min_count }, @callback

			it "should get the batch of summarized updates", ->
				@UpdatesManager._extendBatchOfSummarizedUpdates
					.calledWith(@project_id, [], @before, @min_count)
					.should.equal true

			it "should call the callback with the updates", ->
				@callback.calledWith(null, @updates, @nextBeforeTimestamp).should.equal true

		describe "when multiple batches are needed to meet the limit", ->
			beforeEach ->
				@before = Date.now()
				@min_count = 4
				@firstBatch =  [{ toV: 6, fromV: 6 }, { toV: 5, fromV: 5 }]
				@nextBeforeTimestamp = @before - 100
				@secondBatch = [{ toV: 4, fromV: 4 }, { toV: 3, fromV: 3 }]
				@nextNextBeforeTimestamp = @before - 200
				@UpdatesManager._extendBatchOfSummarizedUpdates = (project_id, existingUpdates, before, desiredLength, callback) =>
					if existingUpdates.length == 0
						callback null, @firstBatch, @nextBeforeTimestamp
					else
						callback null, @firstBatch.concat(@secondBatch), @nextNextBeforeTimestamp
				sinon.spy @UpdatesManager, "_extendBatchOfSummarizedUpdates"
				@UpdatesManager.getSummarizedProjectUpdates @project_id, { before: @before, min_count: @min_count }, @callback

			it "should get the first batch of summarized updates", ->
				@UpdatesManager._extendBatchOfSummarizedUpdates
					.calledWith(@project_id, [], @before, @min_count)
					.should.equal true

			it "should get the second batch of summarized updates", ->
				@UpdatesManager._extendBatchOfSummarizedUpdates
					.calledWith(@project_id, @firstBatch, @nextBeforeTimestamp, @min_count)
					.should.equal true

			it "should call the callback with all the updates", ->
				@callback.calledWith(null, @firstBatch.concat(@secondBatch), @nextNextBeforeTimestamp).should.equal true

		describe "when the end of the database is hit", ->
			beforeEach ->
				@before = Date.now()
				@min_count = 4
				@updates =  [{ toV: 6, fromV: 6 }, { toV: 5, fromV: 5 }]
				@UpdatesManager._extendBatchOfSummarizedUpdates = sinon.stub().callsArgWith(4, null, @updates, null)
				@UpdatesManager.getSummarizedProjectUpdates @project_id, { before: @before, min_count: @min_count }, @callback

			it "should get the batch of summarized updates", ->
				@UpdatesManager._extendBatchOfSummarizedUpdates
					.calledWith(@project_id, [], @before, @min_count)
					.should.equal true

			it "should call the callback with the updates", ->
				@callback.calledWith(null, @updates, null).should.equal true

	describe "fillUserInfo", ->
		describe "with valid users", ->
			beforeEach (done) ->
				{ObjectId} = require "mongojs"
				@user_id_1 = ObjectId().toString()
				@user_id_2 = ObjectId().toString()
				@updates = [{
					meta:
						user_id: @user_id_1
					op: "mock-op-1"
				}, {
					meta:
						user_id: @user_id_1
					op: "mock-op-2"
				}, {
					meta:
						user_id: @user_id_2
					op: "mock-op-3"
				}]
				@user_info = {}
				@user_info[@user_id_1] = email: "user1@sharelatex.com"
				@user_info[@user_id_2] = email: "user2@sharelatex.com"
				
				@WebApiManager.getUserInfo = (user_id, callback = (error, userInfo) ->) =>
					callback null, @user_info[user_id]
				sinon.spy @WebApiManager, "getUserInfo"

				@UpdatesManager.fillUserInfo @updates, (error, @results) =>
					done()

			it "should only call getUserInfo once for each user_id", ->
				@WebApiManager.getUserInfo.calledTwice.should.equal true
				@WebApiManager.getUserInfo
					.calledWith(@user_id_1)
					.should.equal true
				@WebApiManager.getUserInfo
					.calledWith(@user_id_2)
					.should.equal true

			it "should return the updates with the user info filled", ->
				expect(@results).to.deep.equal [{
					meta:
						user:
							email: "user1@sharelatex.com"
					op: "mock-op-1"
				}, {
					meta:
						user:
							email: "user1@sharelatex.com"
					op: "mock-op-2"
				}, {
					meta:
						user:
							email: "user2@sharelatex.com"
					op: "mock-op-3"
				}]


		describe "with invalid user ids", ->
			beforeEach (done) ->
				@updates = [{
					meta:
						user_id: null
					op: "mock-op-1"
				}, {
					meta:
						user_id: "anonymous-user"
					op: "mock-op-2"
				}]
				@WebApiManager.getUserInfo = (user_id, callback = (error, userInfo) ->) =>
					callback null, @user_info[user_id]
				sinon.spy @WebApiManager, "getUserInfo"

				@UpdatesManager.fillUserInfo @updates, (error, @results) =>
					done()

			it "should not call getUserInfo", ->
				@WebApiManager.getUserInfo.called.should.equal false

			it "should return the updates without the user info filled", ->
				expect(@results).to.deep.equal [{
					meta: {}
					op: "mock-op-1"
				}, {
					meta: {}
					op: "mock-op-2"
				}]

	describe "_summarizeUpdates", ->
		beforeEach ->
			@now = Date.now()
			@user_1 = { id: "mock-user-1" }
			@user_2 = { id: "mock-user-2" }

		it "should concat updates that are close in time", ->
			result = @UpdatesManager._summarizeUpdates [{
				doc_id: "doc-id-1"
				meta:
					user: @user_1
					start_ts: @now + 20
					end_ts:   @now + 30
				v: 5
			}, {
				doc_id: "doc-id-1"
				meta:
					user: @user_2
					start_ts: @now
					end_ts:   @now + 10
				v: 4
			}]

			expect(result).to.deep.equal [{
				docs:
					"doc-id-1":
						fromV: 4
						toV: 5
				meta:
					users: [@user_1, @user_2]
					start_ts: @now
					end_ts:   @now + 30
			}]

		it "should leave updates that are far apart in time", ->
			oneDay = 1000 * 60 * 60 * 24
			result = @UpdatesManager._summarizeUpdates [{
				doc_id: "doc-id-1"
				meta:
					user: @user_2
					start_ts: @now + oneDay
					end_ts:   @now + oneDay + 10
				v: 5
			}, {
				doc_id: "doc-id-1"
				meta:
					user: @user_1
					start_ts: @now
					end_ts:   @now + 10
				v: 4
			}]
			expect(result).to.deep.equal [{
				docs:
					"doc-id-1":
						fromV: 5
						toV: 5
				meta:
					users: [@user_2]
					start_ts: @now + oneDay
					end_ts:   @now + oneDay + 10
			}, {
				docs:
					"doc-id-1":
						fromV: 4
						toV: 4
				meta:
					users: [@user_1]
					start_ts: @now
					end_ts:   @now + 10
			}]

		it "should concat onto existing summarized updates", ->
			result = @UpdatesManager._summarizeUpdates [{
				doc_id: "doc-id-2"
				meta:
					user: @user_1
					start_ts: @now + 20
					end_ts:   @now + 30
				v: 5
			}, {
				doc_id: "doc-id-2"
				meta:
					user: @user_2
					start_ts: @now
					end_ts:   @now + 10
				v: 4
			}], [{
				docs: 
					"doc-id-1": 
						fromV: 6
						toV: 8
				meta:
					users: [@user_1]
					start_ts: @now + 40
					end_ts:   @now + 50
			}]
			expect(result).to.deep.equal [{
				docs:
					"doc-id-1":
						toV: 8
						fromV: 6
					"doc-id-2":
						toV: 5
						fromV: 4
				meta:
					users: [@user_1, @user_2]
					start_ts: @now
					end_ts:   @now + 50
			}]
