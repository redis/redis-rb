# frozen_string_literal: true

require "helper"

class TestCommandsOnSearchMiscellaneous < Minitest::Test
  include Helper::Client
  include Redis::Commands::Search

  def setup
    super
    @index_name = "test_index"
    r.select(0)

    # Check if Search module is available
    begin
      r.call('FT._LIST')
    rescue Redis::CommandError
      skip "Search module not available"
    end

    begin
      r.ft_dropindex(@index_name, delete_documents: true)
    rescue
      nil
    end
  end

  def test_ft_sugadd_and_sugget
    r.ft_sugadd('ac', 'hello world', 1.0)
    suggestions = r.ft_sugget('ac', 'he', fuzzy: true, max: 10)
    assert_equal ['hello world'], suggestions
  end

  def test_ft_sugadd_and_sugget_with_scores
    r.ft_sugadd('ac', 'hello world', 1.0)
    suggestions_with_scores = r.ft_sugget('ac', 'he', with_scores: true)
    # Verify we get the suggestion and a score
    assert_equal 2, suggestions_with_scores.size
    assert_equal 'hello world', suggestions_with_scores[0]
    assert suggestions_with_scores[1].to_f > 0
  end

  def test_ft_sugdel_and_suglen
    r.ft_sugadd('ac', 'hello world', 1.0)
    assert_equal 1, r.ft_suglen('ac')

    r.ft_sugdel('ac', 'hello world')
    assert_equal 0, r.ft_suglen('ac')
  end

  def test_ft_dictadd_del_dump
    terms = %w[term1 term2]
    dict_name = 'test_dict'

    # Add terms and check count
    added_count = r.ft_dictadd(dict_name, *terms)
    assert_equal 2, added_count

    # Delete a term and check count
    deleted_count = r.ft_dictdel(dict_name, 'term1')
    assert_equal 1, deleted_count

    # Dump remaining terms
    dumped_terms = r.ft_dictdump(dict_name)
    assert_equal ['term2'], dumped_terms
  end

  def test_ft_tagvals
    schema = Schema.build do
      tag_field :category
    end
    index = r.create_index(@index_name, schema, prefix: "hsh12")

    index.add('doc1', category: 'A,B')
    index.add('doc2', category: 'C')

    tag_values = r.ft_tagvals(@index_name, 'category')
    # Redis normalizes tags to lowercase by default (unless CASESENSITIVE is used)
    assert_equal ['a', 'b', 'c'].sort, tag_values.sort
  end

  def test_ft_spellcheck
    schema = Schema.build do
      text_field :title
    end
    index = r.create_index(@index_name, schema)
    index.add('doc1', title: 'hello')

    # Wait for index to be ready
    sleep 0.1

    result = r.ft_spellcheck(@index_name, 'hell')
    # Verify the structure: [['TERM', 'hell', [[score, 'hello']]]]
    assert_equal 1, result.size
    assert_equal 'TERM', result[0][0]
    assert_equal 'hell', result[0][1]
    assert_equal 1, result[0][2].size
    assert result[0][2][0][0].to_f > 0 # Score
    assert_equal 'hello', result[0][2][0][1] # Suggestion
  end

  def test_ft_spellcheck_with_distance
    schema = Schema.build do
      text_field :title
    end
    index = r.create_index(@index_name, schema)
    index.add('doc1', title: 'hello')

    # Wait for index to be ready
    sleep 0.1

    result_dist_1 = r.ft_spellcheck(@index_name, 'hell', distance: 1)
    # Verify the structure
    assert_equal 1, result_dist_1.size
    assert_equal 'TERM', result_dist_1[0][0]
    assert_equal 'hell', result_dist_1[0][1]
    assert_equal 'hello', result_dist_1[0][2][0][1]

    result_dist_2 = r.ft_spellcheck(@index_name, 'helo', distance: 2)
    assert_equal 1, result_dist_2.size
    assert_equal 'TERM', result_dist_2[0][0]
    assert_equal 'helo', result_dist_2[0][1]
    assert_equal 'hello', result_dist_2[0][2][0][1]
  end

  def test_ft_synupdate_and_syndump
    schema = Schema.build do
      text_field :name
    end
    r.ft_create(@index_name, schema)

    # NOTE: SYNONYM is not supported in the current Schema API
    # Add synonyms using ft_synupdate
    r.ft_synupdate(@index_name, 'group1', 'guy', 'dude')
    r.ft_synupdate(@index_name, 'group1', 'boy')
    synonyms = r.ft_syndump(@index_name)
    assert_equal({ 'guy' => ['group1'], 'dude' => ['group1'], 'boy' => ['group1'] }, synonyms)
  end

  def test_ft_alias_add_update_del
    schema = Schema.build do
      text_field :title
    end
    index = r.create_index(@index_name, schema, prefix: "alias_test")
    alias_name = 'test_alias'

    # Add alias
    assert r.ft_aliasadd(alias_name, @index_name)

    # Check alias by searching
    index.add('doc1', title: 'test')
    result = r.ft_search(alias_name, 'test')
    assert_equal 1, result[0]

    # Create a second index to update the alias to
    new_index_name = 'new_index'
    schema2 = Schema.build do
      text_field :title
    end
    r.create_index(new_index_name, schema2)

    # Update alias to point to the new index
    assert r.ft_aliasupdate(alias_name, new_index_name)

    # Delete alias
    assert r.ft_aliasdel(alias_name)

    # Clean up the second index
    r.ft_dropindex(new_index_name)
  end
end
