require File.dirname(__FILE__) + '/spec_helper'

describe "redis" do
  before do
    @r = Redis.new
    @r['foo'] = 'bar'
  end  
  
  it "should be able to GET a key" do
    @r['foo'].should == 'bar'
  end
  
  it "should be able to SET a key" do
    @r['foo'] = 'nik'
    @r['foo'].should == 'nik'
  end
  
  it "should be able to SETNX(set_unless_exists)" do
    @r['foo'] = 'nik'
    @r['foo'].should == 'nik'
    @r.set_unless_exists 'foo', 'bar'
    @r['foo'].should == 'nik'
  end
  
  it "should be able to INCR(increment) a key" do
    @r.delete('counter')
    @r.incr('counter').should == 1
    @r.incr('counter').should == 2
    @r.incr('counter').should == 3
  end
  
  it "should be able to DECR(decrement) a key" do
    @r.decr('counter').should == 2
    @r.decr('counter').should == 1
    @r.decr('counter').should == 0
  end
  
  it "should be able to RANDKEY(return a random key)" do
    @r.randkey.should_not be_nil
  end
  
  it "should be able to RENAME a key" do
    @r.delete 'foo'
    @r.delete 'bar'
    @r['foo'] = 'hi'
    @r.rename! 'foo', 'bar'
    @r['bar'].should == 'hi'
  end
  
  it "should be able to RENAMENX(rename unless the new key already exists) a key" do
    @r.delete 'foo'
    @r.delete 'bar'
    @r['foo'] = 'hi'
    @r['bar'] = 'ohai'
    lambda {@r.rename 'foo', 'bar'}.should raise_error(RedisError)
    @r['bar'].should == 'ohai'
    
  end

end