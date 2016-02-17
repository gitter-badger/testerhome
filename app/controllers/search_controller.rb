class SearchController < ApplicationController
  def index
    search_params = {
        sort: [
            {updated_at: {order: "desc", ignore_unmapped: true}},
            {excellent: {order: "desc", ignore_unmapped: true}}
        ],
        query: {
            multi_match: {
                query: params[:q],
                fields: ['title', 'body', 'name', 'login'],
                fuzziness: 2,
                prefix_length: 5,
                operator: :and
            }
        },
        highlight: {
            pre_tags: ["[h]"],
            post_tags: ["[/h]"],
            fields: {title: {}, body: {}, name: {}, login: {}}
        }
    }
    @result = Elasticsearch::Model.search(search_params, [Topic, User, Page]).paginate(page: params[:page], per_page: 30)
  end
end