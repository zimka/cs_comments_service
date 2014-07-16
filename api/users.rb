require 'new_relic/agent/method_tracer'

post "#{APIPREFIX}/users" do
  user = User.new(external_id: params["id"])
  user.username = params["username"]
  user.save
  if user.errors.any?
    error 400, user.errors.full_messages.to_json
  else
    user.to_hash.to_json
  end
end

get "#{APIPREFIX}/users/:user_id" do |user_id|
  begin
    # Get any group_ids that may have been specified (will be an empty list if none specified).
    group_ids = get_group_ids_from_params(params)
    user.to_hash(complete: bool_complete, course_id: params["course_id"], group_ids: group_ids).to_json
  rescue Mongoid::Errors::DocumentNotFound
    error 404
  end
end

get "#{APIPREFIX}/users/:user_id/active_threads" do |user_id|
  return {}.to_json if not params["course_id"]

  page = (params["page"] || DEFAULT_PAGE).to_i
  per_page = (params["per_page"] || DEFAULT_PER_PAGE).to_i
  per_page = DEFAULT_PER_PAGE if per_page <= 0

  active_contents = Content.where(author_id: user_id, anonymous: false, anonymous_to_peers: false, course_id: params["course_id"])
                           .order_by(updated_at: :desc)

  # Get threads ordered by most recent activity, taking advantage of the fact
  # that active_contents is already sorted that way
  active_thread_ids = active_contents.inject([]) do |thread_ids, content|
    thread_id = content._type == "Comment" ? content.comment_thread_id : content.id
    thread_ids << thread_id if not thread_ids.include?(thread_id)
    thread_ids
  end

  threads = CommentThread.in({"_id" => active_thread_ids})

  group_ids = get_group_ids_from_params(params)
  if not group_ids.empty?
    threads = get_group_id_criteria(threads, group_ids)
  end

  num_pages = [1, (threads.count / per_page.to_f).ceil].max
  page = [num_pages, [1, page].max].min

  sorted_threads = threads.sort_by {|t| active_thread_ids.index(t.id)}
  paged_threads = sorted_threads[(page - 1) * per_page, per_page]

  presenter = ThreadListPresenter.new(paged_threads, user, params[:course_id])
  collection = presenter.to_hash

  json_output = nil
  self.class.trace_execution_scoped(['Custom/get_user_active_threads/json_serialize']) do
    json_output = {
      collection: collection,
      num_pages: num_pages,
      page: page,
    }.to_json
  end
  json_output

end

put "#{APIPREFIX}/users/:user_id" do |user_id|
  user = User.find_or_create_by(external_id: user_id)
  user.update_attributes(params.slice(*%w[username default_sort_key]))
  if user.errors.any?
    error 400, user.errors.full_messages.to_json
  else
    user.to_hash.to_json
  end
end

get "#{APIPREFIX}/users/:user_id/social_stats" do |user_id|
  begin
    return {}.to_json if not params["course_id"]

    course_id = params["course_id"]

    user_stats = {}
    thread_ids = {}

    # get all metadata regarding forum content, but don't bother to fetch the body
    # as we don't need it and we shouldn't push all that data over the wire
    if user_id == "*" then
      content = Content.where(course_id: course_id).without(:body)
    else
      content = Content.where(author_id: user_id, course_id: course_id).without(:body)
      user_stats[user_id] = {
        "num_threads" => 0,
        "num_comments" => 0,
        "num_replies" => 0,
        "num_upvotes" => 0,
        "num_downvotes" => 0,
        "num_flagged" => 0,
        "num_comments_generated" => 0
      }
      thread_ids[user_id] = []
    end

    content.each do |item|
      user_id = item.author_id

      if user_stats.key?(user_id) == false then
        user_stats[user_id] = {
          "num_threads" => 0,
          "num_comments" => 0,
          "num_replies" => 0,
          "num_upvotes" => 0,
          "num_downvotes" => 0,
          "num_flagged" => 0,
          "num_comments_generated" => 0
        }
        thread_ids[user_id] = []
      end

      if item._type == "CommentThread" then
        user_stats[user_id]["num_threads"] += 1
        thread_ids[user_id].push(item._id)
        user_stats[user_id]["num_comments_generated"] += item.comment_count
      elsif item._type == "Comment" and item.parent_ids == [] then
        user_stats[user_id]["num_comments"] += 1
      else
        user_stats[user_id]["num_replies"] += 1
      end

      # don't allow for self-voting
      item.votes["up"].delete(user_id)
      item.votes["down"].delete(user_id)

      user_stats[user_id]["num_upvotes"] += item.votes["up"].count
      user_stats[user_id]["num_downvotes"] += item.votes["down"].count

      user_stats[user_id]["num_flagged"] += item.abuse_flaggers.count
    end

    # with the array of objectId's for threads, get a count of number of other users who have a subscription on it
    user_stats.keys.each do |user_id|
      user_stats[user_id]["num_thread_followers"] = Subscription.where(:subscriber_id.ne => user_id, :source_id.in => thread_ids[user_id]).count()
    end

    user_stats.to_json
  end
end


