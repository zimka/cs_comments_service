require 'spec_helper'
require 'unicode_shared_examples'

describe "app" do
  describe "users" do
    before :each do
      User.delete_all
      create_test_user 1
      create_test_user 2
      set_api_key_header
    end
    describe "POST /api/v1/users" do
      it "creates a user" do
        post "/api/v1/users", id: "100", username: "user100"
        last_response.should be_ok
        user = User.find_by(external_id: "100")
        user.username.should == "user100"
      end
      it "returns error when id / username already exists" do
        post "/api/v1/users", id: "1", username: "user100"
        last_response.status.should == 400
        post "/api/v1/users", id: "100", username: "user1"
        last_response.status.should == 400
      end
    end
    describe "PUT /api/v1/users/:user_id" do
      it "updates user information" do
        put "/api/v1/users/1", username: "new_user_1"
        last_response.should be_ok
        user = User.find_by("1")
        user.username.should == "new_user_1"
      end
      it "does not update id" do
        put "/api/v1/users/1", id: "100"
        last_response.should be_ok
        user = User.find_by("1")
        user.should_not be_nil
      end
      it "returns error if user does not exist" do
        put "/api/v1/users/100", id: "100"
        last_response.status.should == 400
      end
      it "returns error if new information has conflict with other users" do
        put "/api/v1/users/1", username: "user2"
        last_response.status.should == 400 
      end
    end
    describe "GET /api/v1/users/:user_id" do
      it "returns user information" do
        get "/api/v1/users/1"
        last_response.status.should == 200
        res = parse(last_response.body)
        user1 = User.find_by("1")
        res["external_id"].should == user1.external_id
        res["username"].should == user1.username
      end
      it "returns 404 if user does not exist" do
        get "/api/v1/users/3"
        last_response.status.should == 404
      end
      describe "Returns threads_count and comments_count" do
          before(:each) { setup_10_threads }

          def create_thread_and_comment_in_specific_group(user_id, group_id, thread)
             # Changes the specified thread and a comment within that thread to be authored by the
             # specified user in the specified group_id.
             @threads[thread].author = @users["u"+user_id]
             @threads[thread].group_id = group_id
             @threads[thread].save!
             first_comment_in_thread = thread + " c1"
             @comments[first_comment_in_thread].author = @users["u"+user_id]
             @comments[first_comment_in_thread].save!
          end

          def verify_counts(expected_threads, expected_comments, user_id, group_id=nil)
             if group_id
                get "/api/v1/users/" + user_id, course_id: "xyz", group_id: group_id
             else
                get "/api/v1/users/" + user_id, course_id: "xyz"
             end
             parse_response_and_verify_counts(expected_threads, expected_comments)
          end

          def verify_counts_multiple_groups(expected_threads, expected_comments, user_id, group_ids)
             get "/api/v1/users/" + user_id, course_id: "xyz", group_ids: group_ids
             parse_response_and_verify_counts(expected_threads, expected_comments)
          end

          def parse_response_and_verify_counts(expected_threads, expected_comments)
             res = parse(last_response.body)
             res["threads_count"].should == expected_threads
             res["comments_count"].should == expected_comments
          end

          it "returns threads_count and comments_count" do
             # "setup_10_threads" creates 1 thread ("t0") and 5 comments (in "t0") authored by user 100.
             verify_counts(1, 5, "100")
          end

          it "returns threads_count and comments_count irrespective of group_id, if group_id is not specified" do
             # Now change thread "t1" and comment in "t1" to be authored by user 100, but in a group (43).
             # As long as we don't ask for user info for a specific group, these will always be included.
             create_thread_and_comment_in_specific_group("100", 43, "t1")
             verify_counts(2, 6, "100")
          end

          it "returns threads_count and comments_count filtered by group_id, if group_id is specified" do
             create_thread_and_comment_in_specific_group("100", 43, "t1")

             # The threads and comments created by "setup_10_threads" do not have a group_id specified, so are
             # visible to all (group_id=3000 specified).
             verify_counts(1, 5, "100", 3000)

             # There is one additional thread and comment (created by create_thread_and_comment_in_specific_group),
             # visible to only group_id 43.
             verify_counts(2, 6, "100", 43)
          end

          it "handles comments correctly on threads not started by the author" do
             # "setup_10_threads" creates 1 thread ("t1") and 5 comments (in "t1") authored by user 101.
             verify_counts(1, 5, "101")

             # The next call makes user 100 the author of "t1" and "t1 c1" (within group_id 43).
             create_thread_and_comment_in_specific_group("100", 43, "t1")

             # Therefore user 101 is now just the author of 4 comments.
             verify_counts(0, 4, "101")

             # We should get the same comment count when specifically asking for comments within group_id 43.
             verify_counts(0, 4, "101", 43)

             # We should get no comments for a different group.
             verify_counts(0, 0, "101", 3000)
          end

          it "can return comments and threads for multiple groups" do
             create_thread_and_comment_in_specific_group("100", 43, "t1")
             create_thread_and_comment_in_specific_group("100", 3000, "t2")

             # user 100 is now the author of:
             #    visible to all groups-- 1 thread ("t0") and 5 comments
             #    visible to group_id 43-- 1 thread ("t1") and 1 comment
             #    visible to group_id 3000-- 1 thread ("t2") and 1 comment
             verify_counts(3, 7, "100")
             verify_counts_multiple_groups(3, 7, "100", "")
             verify_counts_multiple_groups(3, 7, "100", "43, 3000")
             verify_counts_multiple_groups(3, 7, "100", "43, 3000, 8")
             verify_counts_multiple_groups(2, 6, "100", "43")
             verify_counts_multiple_groups(2, 6, "100", "3000")
             verify_counts_multiple_groups(1, 5, "100", "8")
          end
      end
    end
    describe "GET /api/v1/users/:user_id/active_threads" do

      before(:each) { setup_10_threads }

      def thread_result(user_id, params)
        get "/api/v1/users/#{user_id}/active_threads", params
        last_response.should be_ok
        parse(last_response.body)["collection"]
      end

      it "requires that a course id be passed" do
        get "/api/v1/users/100/active_threads"
        # this is silly, but it is the legacy behavior
        last_response.should be_ok
        last_response.body.should == "{}"
      end

      it "only returns threads with activity from the specified user"  do
        @comments["t3 c4"].author = @users["u100"]
        @comments["t3 c4"].save!
        rs = thread_result 100, course_id: "xyz"
        rs.length.should == 2
        check_thread_result_json(@users["u100"], @threads["t3"], rs[0])
        check_thread_result_json(@users["u100"], @threads["t0"], rs[1])
      end

      it "filters by group_id" do
        @threads["t1"].author = @users["u100"]
        @threads["t1"].save!
        rs = thread_result 100, course_id: DFLT_COURSE_ID, group_id: 42
        rs.length.should == 2
        @threads["t1"].group_id = 43
        @threads["t1"].save!
        rs = thread_result 100, course_id: DFLT_COURSE_ID, group_id: 42
        rs.length.should == 1
        @threads["t1"].group_id = 42
        @threads["t1"].save!
        rs = thread_result 100, course_id: DFLT_COURSE_ID, group_id: 42
        rs.length.should == 2
      end

      it "filters by group_ids" do
        @threads["t1"].author = @users["u100"]
        @threads["t1"].save!
        rs = thread_result 100, course_id: DFLT_COURSE_ID, group_ids: "42"
        rs.length.should == 2
        @threads["t1"].group_id = 43
        @threads["t1"].save!
        rs = thread_result 100, course_id: DFLT_COURSE_ID, group_ids: "42"
        rs.length.should == 1
        rs = thread_result 100, course_id: DFLT_COURSE_ID, group_ids: "42,43"
        rs.length.should == 2
      end

      it "does not return threads in which the user has only participated anonymously" do
        @comments["t3 c4"].author = @users["u100"]
        @comments["t3 c4"].anonymous_to_peers = true
        @comments["t3 c4"].save!
        @comments["t5 c1"].author = @users["u100"]
        @comments["t5 c1"].anonymous = true
        @comments["t5 c1"].save!
        rs = thread_result 100, course_id: "xyz"
        rs.length.should == 1
        check_thread_result_json(@users["u100"], @threads["t0"], rs.first)
      end      

      it "only returns threads from the specified course" do
        @threads.each do |k, v|
          v.author = @users["u100"]
          v.save!
        end
        @threads["t9"].course_id = "zzz"
        @threads["t9"].save!
        rs = thread_result 100, course_id: "xyz"
        rs.length.should == 9
      end

      it "correctly orders results by most recent update by selected user" do
        user = @users["u100"]
        base_time = DateTime.now
        @comments["t2 c2"].author = user
        @comments["t2 c2"].updated_at = base_time
        @comments["t2 c2"].save!
        @comments["t4 c4"].author = user
        @comments["t4 c4"].updated_at = base_time + 1
        @comments["t4 c4"].save!
        @threads["t2"].updated_at = base_time + 2
        @threads["t2"].save!
        @threads["t3"].author = user
        @threads["t3"].updated_at = base_time + 4
        @threads["t3"].save!
        rs = thread_result 100, course_id: "xyz"
        actual_order = rs.map {|v| v["title"]}
        actual_order.should == ["t3", "t4", "t2", "t0"]
      end

      context "pagination" do
        def thread_result_page (page, per_page)
          get "/api/v1/users/100/active_threads", course_id: "xyz", page: page, per_page: per_page
          last_response.should be_ok
          parse(last_response.body)
        end

        before(:each) do
          @comments.each do |k, v|
            @comments[k].author = @users["u100"]
            @comments[k].save!
          end
        end

        it "returns single page" do
          result = thread_result_page(1, 20)
          result["collection"].length.should == 10
          result["num_pages"].should == 1
          result["page"].should == 1
        end
        it "returns multiple pages" do
          result = thread_result_page(1, 5)
          result["collection"].length.should == 5
          result["num_pages"].should == 2
          result["page"].should == 1

          result = thread_result_page(2, 5)
          result["collection"].length.should == 5
          result["num_pages"].should == 2
          result["page"].should == 2
        end
        it "orders correctly across pages" do
          expected_order = @threads.keys.reverse 
          actual_order = []
          per_page = 3
          num_pages = (@threads.length + per_page - 1) / per_page
          num_pages.times do |i|
            page = i + 1
            result = thread_result_page(page, per_page)
            result["collection"].length.should == (page * per_page <= @threads.length ? per_page : @threads.length % per_page)
            result["num_pages"].should == num_pages
            result["page"].should == page
            actual_order += result["collection"].map {|v| v["title"]}
          end
          actual_order.should == expected_order
        end
        it "accepts negative parameters" do
          result = thread_result_page(-5, -5)
          result["collection"].length.should == 10
          result["num_pages"].should == 1
          result["page"].should == 1
        end
        it "accepts excessively large parameters" do
          result = thread_result_page(9999, 9999)
          result["collection"].length.should == 10
          result["num_pages"].should == 1
          result["page"].should == 1
        end
        it "accepts empty parameters" do
          result = thread_result_page("", "")
          result["collection"].length.should == 10
          result["num_pages"].should == 1
          result["page"].should == 1
        end
      end

      def test_unicode_data(text)
        user = User.first
        course_id = "unicode_course"
        thread = make_thread(user, text, course_id, "unicode_commentable")
        make_comment(user, thread, text)
        result = thread_result(user.id, course_id: course_id)
        result.length.should == 1
        check_thread_result_json(nil, thread, result.first)
      end

      include_examples "unicode data"
    end

    describe "GET /api/v1/users/:user_id/social_stats" do
      before :each do
        User.delete_all
        Content.all.delete
        @user1 = create_test_user 1
        @user2 = create_test_user 2
        @user3 = create_test_user 3
        @user4 = create_test_user 4
      end

      def check_social_stats(response, expected)
        expected.each do |key, value|
          response[key].should == value
        end
      end

      def make_social_stats(
        num_threads, num_comments, num_replies, num_upvotes,
        num_downvotes, num_flagged, num_comments_generated, num_thread_followers,
        num_threads_read
      )
        {
          "num_threads" => num_threads,
          "num_comments" => num_comments,
          "num_replies" => num_replies,
          "num_upvotes" => num_upvotes,
          "num_downvotes" => num_downvotes,
          "num_flagged" => num_flagged,
          "num_comments_generated" => num_comments_generated,
          "num_thread_followers" => num_thread_followers,
          "num_threads_read" => num_threads_read,
        }
      end

      def make_request(user_id, course_id, end_date=nil, thread_type=nil)
        parameters = { :course_id => course_id}
        if end_date
          parameters['end_date'] = end_date
        end
        if thread_type
          parameters['thread_type'] = thread_type
        end

        get "/api/v1/users/#{user_id}/social_stats", parameters

        last_response.status.should == 200
        parse(last_response.body)
      end

      def set_votes(user, direction, contents)
        contents.each do |content|
          content.votes[direction].push(user.id)
          content.save!
        end
      end

      def set_flags(user, contents)
        contents.each do |content|
          content.abuse_flaggers.push(user.id)
          content.save!
        end
      end

      def subscribe(content, users) 
        users.each do |user|
          user.subscribe(content)
        end
      end

      it "returns nothing for missing course" do
        get "/api/v1/users/1/social_stats"
        last_response.status.should == 200
        res = parse(last_response.body)
        res.should == {}

        get "/api/v1/users/1/social_stats", course: "missing_course"
        last_response.status.should == 200
        res = parse(last_response.body)
        res.should == {}

        get "/api/v1/users/*/social_stats", course: "missing_course"
        last_response.status.should == 200
        res = parse(last_response.body)
        res.should == {}
      end

      describe "single user" do
        it "returns zeroes for missing user" do
          check_social_stats(make_request(10000, DFLT_COURSE_ID), {"10000" => make_social_stats(0,0,0,0,0,0,0,0,0)})
        end

        it "returns zeroes for existing user with no activity" do
          thread = make_thread(@user1, "irrelevant text", DFLT_COURSE_ID, "irrelevant commentable_id")
          check_social_stats(make_request(@user2.id, DFLT_COURSE_ID), {@user2.id => make_social_stats(0,0,0,0,0,0,0,0,0)})
        end

        [1,2].each do |thread_count|
          [0,3].each do |comment_count|
            [2,0,4].each do |reply_count|
              it "returns correct thread, comment, reply and comments generated count (#{thread_count}, #{comment_count}, #{reply_count})" do
                check_social_stats(make_request(@user2.id, DFLT_COURSE_ID), {@user2.id => make_social_stats(0,0,0,0,0,0,0,0,0)})

                fixed_thread = make_thread(@user2, "Fixed thread", DFLT_COURSE_ID, "fixed_thread")
                fixed_comment = make_comment(@user2, fixed_thread, "fixed comemnt text")

                check_social_stats(make_request(@user2.id, DFLT_COURSE_ID), {@user2.id => make_social_stats(1,1,0,0,0,0,1,0,0)})

                thread_count.times {|i| make_thread(@user1, "text#{i}", DFLT_COURSE_ID, "commentable_id#{i}") }
                comment_count.times {|i|  make_comment(@user1, fixed_thread, "comment#{i}") }
                reply_count.times {|i| make_comment(@user1, fixed_comment, "response#{i}")}

                # precondition - checking that user2 has only one thread and one comment - the fixed ones
                check_social_stats(make_request(@user2.id, DFLT_COURSE_ID), {@user2.id => make_social_stats(1,1,0,0,0,0,comment_count+reply_count+1,0,0)})

                check_social_stats(make_request(@user1.id, DFLT_COURSE_ID), {@user1.id => make_social_stats(thread_count,comment_count,reply_count,0,0,0,0,0,0)})
              end
            end
          end
        end

        it "self-comments and self-replies are counted toward generated_comments" do
          thread = make_thread(@user1, "Some thread", DFLT_COURSE_ID, "Thread 1")
          comment = make_comment(@user1, thread, "Comment1-1")
          reply = make_comment(@user1, comment, "Reply1-1-1")

          check_social_stats(make_request(@user1.id, DFLT_COURSE_ID), {@user1.id => make_social_stats(1,1,1,0,0,0,2,0,0)})
        end

        it "returns correct upvotes and downvotes count" do
          thread1 = make_thread(@user2, "Some thread", DFLT_COURSE_ID, "Thread 1")
          thread2 = make_thread(@user2, "Some other thread", DFLT_COURSE_ID, "Thread 2")
          comment1 = make_comment(@user2, thread1, "Comment1-1")
          comment2 = make_comment(@user2, thread1, "Comment1-2")
          reply1 = make_comment(@user2, comment1, "Reply1-1-1")
          reply2 = make_comment(@user2, comment2, "Reply1-2-1")

          set_votes(@user1, "up", [thread1, comment2, reply2])
          set_votes(@user1, "down", [thread2, comment1])
          set_flags(@user1, [thread1, thread2, comment1, reply2])

          check_social_stats(make_request(@user2.id, DFLT_COURSE_ID), {@user2.id => make_social_stats(2,2,2,3,2,4,4,0,0)})
        end

        it "ignores self-upvotes and self-downvotes" do
          thread = make_thread(@user1, "Some thread", DFLT_COURSE_ID, "Thread 1")
          comment = make_comment(@user1, thread, "Comment1-1")
          reply = make_comment(@user1, comment, "Reply1-1-1")

          set_votes(@user1, "up", [thread, comment, reply])
          set_votes(@user1, "down", [thread, comment, reply])

          check_social_stats(make_request(@user1.id, DFLT_COURSE_ID), {@user1.id => make_social_stats(1,1,1,0,0,0,2,0,0)})
        end

        it "returns correct follower count" do 
          thread = make_thread(@user1, "Some thread", DFLT_COURSE_ID, "Thread 1")

          subscribe(thread, [@user2, @user3])

          check_social_stats(make_request(@user1.id, DFLT_COURSE_ID), {@user1.id => make_social_stats(1,0,0,0,0,0,0,2,0)})
        end

        it "ignores self-subscriptions" do 
          thread = make_thread(@user1, "Some thread", DFLT_COURSE_ID, "Thread 1")

          subscribe(thread, [@user1])

          check_social_stats(make_request(@user1.id, DFLT_COURSE_ID), {@user1.id => make_social_stats(1,0,0,0,0,0,0,0,0)})
        end

        it "ignores subscriptions to comments and replies" do 
          thread = make_thread(@user1, "Some thread", DFLT_COURSE_ID, "Thread 1")
          comment = make_comment(@user1, thread, "Comment1-1")
          reply = make_comment(@user1, comment, "Reply1-1-1")

          subscribe(comment, [@user2])
          subscribe(reply, [@user2])

          check_social_stats(make_request(@user1.id, DFLT_COURSE_ID), {@user1.id => make_social_stats(1,1,1,0,0,0,2,0,0)})
        end

        it "returns a count of how many threads have been read" do
          thread = make_thread(@user1, "Some thread", DFLT_COURSE_ID, "Thread 1")
          thread2 = make_thread(@user1, "Some other thread", DFLT_COURSE_ID, "Thread 2")
          @user2.mark_as_read(thread)
          check_social_stats(make_request(@user2.id, DFLT_COURSE_ID), {@user2.id => make_social_stats(0,0,0,0,0,0,0,0,1)})
          @user2.mark_as_read(thread2)
          check_social_stats(make_request(@user2.id, DFLT_COURSE_ID), {@user2.id => make_social_stats(0,0,0,0,0,0,0,0,2)})
          # Make sure it also works when selecting all.
          check_social_stats(make_request("*", DFLT_COURSE_ID), {@user2.id => make_social_stats(0,0,0,0,0,0,0,0,2)})
        end

        it "respects end_date parameter when calculating thread, comment, reply and comments generated counts" do
          thread1 = make_thread(@user1, "Some thread", DFLT_COURSE_ID, "Thread 1")
          thread2 = make_thread(@user1, "Other thread", DFLT_COURSE_ID, "Thread 2")
          comment1 = make_comment(@user1, thread1, "Comment1-1")
          comment2 = make_comment(@user1, thread1, "Comment1-2")
          reply1 = make_comment(@user1, comment1, "Reply1-1-1")
          reply2 = make_comment(@user1, comment1, "Reply1-1-2")

          [thread1, comment1, reply1].each do |content|
            content.created_at = DateTime.new(2015, 02, 28)
            content.save!
          end

          [thread2, comment2, reply2].each do |content|
            content.created_at = DateTime.new(2015, 03, 12)
            content.save!
          end

          check_social_stats(make_request(@user1.id, DFLT_COURSE_ID), {@user1.id => make_social_stats(2,2,2,0,0,0,4,0,0)})
          # TODO: looks like a bug, but preserving it for now; comments generated should probably be 2, as comment1 and reply1 were created after end_date
          check_social_stats(make_request(@user1.id, DFLT_COURSE_ID, DateTime.new(2015, 03, 01)), {@user1.id => make_social_stats(1,1,1,0,0,0,4,0,0)})
          check_social_stats(make_request(@user1.id, DFLT_COURSE_ID, DateTime.new(2015, 02, 01)), {@user1.id => make_social_stats(0,0,0,0,0,0,0,0,0)})
        end

        it "respects thread_type parameter when calculating thread, comment, reply and comments generated counts" do
          thread1 = make_thread(@user1, "Some thread", DFLT_COURSE_ID, "Thread 1", :discussion)
          thread2 = make_thread(@user1, "Other thread", DFLT_COURSE_ID, "Thread 2", :question)
          comment1 = make_comment(@user1, thread1, "Comment1-1")
          comment2 = make_comment(@user1, thread2, "Comment2-1")
          comment3 = make_comment(@user1, thread2, "Comment2-2")
          reply1 = make_comment(@user1, comment1, "Reply1-1-1")
          reply2 = make_comment(@user1, comment2, "Reply1-2-1")

          check_social_stats(make_request(@user1.id, DFLT_COURSE_ID, nil), {@user1.id => make_social_stats(2,3,2,0,0,0,5,0,0)})
          check_social_stats(make_request(@user1.id, DFLT_COURSE_ID, nil, :discussion), {@user1.id => make_social_stats(1,1,1,0,0,0,2,0,0)})
          check_social_stats(make_request(@user1.id, DFLT_COURSE_ID, nil, :question), {@user1.id => make_social_stats(1,2,1,0,0,0,3,0,0)})
        end
      end

      describe "all users" do
        before :each do
          @thread1 = make_thread(@user1, "Some thread", DFLT_COURSE_ID, "Thread 1", :discussion)
          @thread2 = make_thread(@user2, "Other thread", DFLT_COURSE_ID, "Thread 2", :discussion)
          @thread3 = make_thread(@user2, "Other thread", DFLT_COURSE_ID, "Thread 2", :question)
          @comment1 = make_comment(@user2, @thread1, "Comment1-1")
          @comment2 = make_comment(@user2, @thread1, "Comment1-2")
          @comment3 = make_comment(@user2, @thread2, "Comment2-1")
          @comment4 = make_comment(@user1, @thread3, "Comment3-1")
          @reply1 = make_comment(@user1, @comment1, "Reply1-1-1")
          @reply2 = make_comment(@user2, @comment1, "Reply1-1-2")
          @reply3 = make_comment(@user1, @comment2, "Reply1-2-1")

          set_votes(@user1, "up", [@thread2, @comment2, @comment3])
          set_votes(@user2, "up", [@thread1, @reply1])
          set_votes(@user3, "up", [@thread1, @thread2, @thread3])

          set_flags(@user1, [@comment1, @comment2, @comment4])
          set_flags(@user2, [@thread1, @reply1])
          set_flags(@user3, [@thread1, @thread2])

          subscribe(@thread1, [@user3])
          subscribe(@thread2, [@user1, @user3])
          subscribe(@thread3, [@user1])
        end

        it "returns correct stats for all users" do
          check_social_stats(make_request('*', DFLT_COURSE_ID), {
            @user1.id => make_social_stats(1,1,2,3,0,4,5,1,0),
            @user2.id => make_social_stats(2,3,1,5,0,3,2,3,0),
          })
        end

        it "filters by end_date" do
          [@thread1, @comment1, @reply1].each do |content|
            content.created_at = DateTime.new(2015, 02, 28)
            content.save!
          end

          [@thread2, @comment2, @reply2].each do |content|
            content.created_at = DateTime.new(2015, 03, 12)
            content.save!
          end

          [@thread3, @comment3, @reply3, @comment4].each do |content|
            content.created_at = DateTime.new(2015, 03, 15)
            content.save!
          end

          check_social_stats(make_request('*', DFLT_COURSE_ID), {
            @user1.id => make_social_stats(1,1,2,3,0,4,5,1,0),
            @user2.id => make_social_stats(2,3,1,5,0,3,2,3,0),
          })

          make_request('*', DFLT_COURSE_ID, DateTime.new(2015, 02, 01)).should == {}

          check_social_stats(make_request('*', DFLT_COURSE_ID, DateTime.new(2015, 03, 01)), {
            @user1.id => make_social_stats(1,0,1,3,0,3,5,1,0),
            @user2.id => make_social_stats(0,1,0,0,0,1,0,0,0),
          })

          check_social_stats(make_request('*', DFLT_COURSE_ID, DateTime.new(2015, 03, 13)), {
            @user1.id => make_social_stats(1,0,1,3,0,3,5,1,0),
            @user2.id => make_social_stats(1,2,1,3,0,3,1,2,0),
          })

          check_social_stats(make_request('*', DFLT_COURSE_ID, DateTime.new(2015, 03, 25)), {
            @user1.id => make_social_stats(1,1,2,3,0,4,5,1,0),
            @user2.id => make_social_stats(2,3,1,5,0,3,2,3,0),
          })
        end

        it "filters by thread_type" do
          check_social_stats(make_request('*', DFLT_COURSE_ID, nil), {
            @user1.id => make_social_stats(1,1,2,3,0,4,5,1,0),
            @user2.id => make_social_stats(2,3,1,5,0,3,2,3,0),
          })

          check_social_stats(make_request('*', DFLT_COURSE_ID, nil, :discussion), {
            @user1.id => make_social_stats(1,0,2,3,0,3,5,1,0),
            @user2.id => make_social_stats(1,3,1,4,0,3,1,2,0),
          })

          check_social_stats(make_request('*', DFLT_COURSE_ID, nil, :question), {
            @user1.id => make_social_stats(0,1,0,0,0,1,0,0,0),
            @user2.id => make_social_stats(1,0,0,1,0,0,1,1,0),
          })
        end
      end
    end
  end
end
