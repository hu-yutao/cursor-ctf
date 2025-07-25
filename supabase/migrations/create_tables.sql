-- 创建用户表
CREATE TABLE IF NOT EXISTS users (
    username TEXT PRIMARY KEY,
    password TEXT NOT NULL,
    total_score INTEGER DEFAULT 0,
    has_claimed_prize BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW()),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW())
);

-- 创建用户 Flag 表
CREATE TABLE IF NOT EXISTS user_flags (
    id BIGINT GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    username TEXT REFERENCES users(username) ON DELETE CASCADE,
    flag_key TEXT NOT NULL,
    points INTEGER NOT NULL,
    unlocked_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW()),
    UNIQUE(username, flag_key)
);

-- 创建更新用户总分的函数
CREATE OR REPLACE FUNCTION update_user_total_score()
RETURNS TRIGGER AS $$
BEGIN
    UPDATE users
    SET total_score = (
        SELECT COALESCE(SUM(points), 0)
        FROM user_flags
        WHERE username = NEW.username
    ),
    updated_at = NOW()
    WHERE username = NEW.username;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 创建触发器，在插入或删除 flag 记录时更新用户总分
CREATE TRIGGER update_score_on_flag_change
AFTER INSERT OR DELETE ON user_flags
FOR EACH ROW
EXECUTE FUNCTION update_user_total_score();

-- 创建获取用户排名的函数
CREATE OR REPLACE FUNCTION get_user_rank(target_username TEXT)
RETURNS INTEGER AS $$
BEGIN
    RETURN (
        SELECT rank
        FROM (
            SELECT username, 
                   RANK() OVER (ORDER BY total_score DESC) as rank
            FROM users
        ) rankings
        WHERE username = target_username
    );
END;
$$ LANGUAGE plpgsql;

-- 创建奖励领取函数
CREATE OR REPLACE FUNCTION claim_prize(target_username TEXT)
RETURNS BOOLEAN AS $$
DECLARE
    user_exists BOOLEAN;
    already_claimed BOOLEAN;
BEGIN
    -- 检查用户是否存在
    SELECT EXISTS(SELECT 1 FROM users WHERE username = target_username) INTO user_exists;
    
    IF NOT user_exists THEN
        RETURN FALSE;
    END IF;
    
    -- 检查是否已经领取过奖励
    SELECT has_claimed_prize INTO already_claimed 
    FROM users 
    WHERE username = target_username;
    
    IF already_claimed THEN
        RETURN FALSE;
    END IF;
    
    -- 更新奖励状态
    UPDATE users 
    SET has_claimed_prize = TRUE, 
        updated_at = NOW()
    WHERE username = target_username;
    
    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 创建 RLS 策略
ALTER TABLE users ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_flags ENABLE ROW LEVEL SECURITY;

-- 用户表的访问策略
CREATE POLICY "允许用户查看所有用户信息" ON users
    FOR SELECT USING (true);

CREATE POLICY "只允许用户更新自己的信息" ON users
    FOR UPDATE USING (auth.uid()::text = username);

-- Flag表的访问策略
CREATE POLICY "允许查看所有Flag记录" ON user_flags
    FOR SELECT USING (true);

CREATE POLICY "只允许用户添加自己的Flag记录" ON user_flags
    FOR INSERT WITH CHECK (auth.uid()::text = username);

-- 创建视图：排行榜
CREATE VIEW leaderboard AS
SELECT 
    u.username,
    u.total_score,
    u.has_claimed_prize,
    COUNT(uf.id) as flags_count,
    get_user_rank(u.username) as rank,
    u.updated_at
FROM users u
LEFT JOIN user_flags uf ON u.username = uf.username
GROUP BY u.username, u.total_score, u.has_claimed_prize, u.updated_at
ORDER BY u.total_score DESC;

-- 添加索引以提高查询性能
CREATE INDEX idx_user_flags_username ON user_flags(username);
CREATE INDEX idx_user_flags_unlocked_at ON user_flags(unlocked_at);
CREATE INDEX idx_users_total_score ON users(total_score DESC); 